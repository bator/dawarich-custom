# frozen_string_literal: true

# Snaps a user's tracks onto their frequent routes (docs/corridors.md): a
# track of a route's mode whose real fixes lie within CORRIDORS_SNAP_BUFFER_M
# of the route for at least CORRIDORS_SNAP_SHARE of their number gets the
# route's line where its stored geometry runs along it; the stored parts
# before and after stay as they were. The geometry before the snap is kept in
# track_corridor_snaps for #revert, with a digest of the geometry written:
# while the track still has it, it is not snapped again; once Dawarich rebuilt
# the geometry (another digest), the new one is the recorded one. A reverted
# track keeps its row (reverted_at) and is not snapped again. Tracks the OSRM
# snap already rewrote are left alone. Every track is measured in local
# metres around its own start (Geometry::Frame), so distances hold anywhere.
class Corridors::Snapper
  G = Corridors::Geometry
  ENDPOINT_M = 150.0
  LENGTH_RATIO = (0.75..1.33) # the route's part vs the real fixes it replaces, else the match is suspicious
  DIGEST_SQL = 'md5(ST_AsBinary(tracks.original_path))'
  # the track still has the geometry the snapper wrote (a row from before the
  # digest: its geometry is not the recorded one)
  STILL_SNAPPED_SQL = "(s.snapped_digest = #{DIGEST_SQL} OR " \
                      '(s.snapped_digest IS NULL AND NOT ST_OrderingEquals(tracks.original_path, s.original_path)))'.freeze
  BATCH = 200 # tracks loaded at once

  Result = Struct.new(:track_id, :outcome, :corridor_id, :share, keyword_init: true)

  def initialize(user)
    @user = user
    @source = Corridors::TripSource.new(user)
  end

  # => [Result]; nothing is written when dry_run
  def call(since: 3.days.ago, dry_run: false)
    routes = TrackCorridor.where(user_id: @user.id).map do |c|
      coords = c.path.points.map { |p| [p.x, p.y] }
      [c, coords, bbox(coords, Corridors::Config.snap_buffer_m + ENDPOINT_M)]
    end
    return [] if routes.empty?

    candidates(since).find_in_batches(batch_size: BATCH).flat_map do |tracks|
      trips = @source.trips_for(tracks.map(&:id))
      tracks.map { |track| snap(track, trips[track.id], routes, dry_run) }
    end
  end

  # Puts back the geometry of every snapped track that still has the snapped
  # one (a track Dawarich rebuilt since already has its recorded geometry).
  # The rows stay, marked reverted, so these tracks are not snapped again.
  def revert(dry_run: false)
    logs = TrackCorridorSnap.where(user_id: @user.id, reverted_at: nil).includes(:track).to_a
    still = TrackCorridorSnap.from('track_corridor_snaps s').joins('JOIN tracks ON tracks.id = s.track_id')
                             .where('s.id': logs.map(&:id)).pluck(Arel.sql('s.id'), Arel.sql(STILL_SNAPPED_SQL)).to_h
    logs.map do |log|
      track = log.track
      unchanged = still[log.id]
      unless dry_run
        TrackCorridorSnap.transaction do
          if unchanged
            track.update_columns(original_path: log.original_path, distance: log.original_distance,
                                 avg_speed: log.original_avg_speed, updated_at: Time.current)
          end
          log.update!(reverted_at: Time.current)
        end
        bump_tiles(track) if unchanged
      end
      Result.new(track_id: track.id, outcome: unchanged ? 'reverted' : 'rebuilt since, nothing to put back')
    end
  end

  private

  # Tracks of the routes' modes from the period, without the OSRM-snapped
  # ones, the reverted ones and those that still have the geometry this
  # snapper wrote.
  def candidates(since)
    scope = @user.tracks.where(dominant_mode: Corridors::Config.modes)
                 .where('tracks.start_at >= :since OR tracks.updated_at >= :since', since:)
    if ActiveRecord::Base.connection.table_exists?(:osrm_snap_log)
      scope = scope.where("NOT EXISTS (SELECT 1 FROM osrm_snap_log o WHERE o.track_id = tracks.id AND o.status = 'snapped')")
    end
    scope.where(<<~SQL.squish)
      NOT EXISTS (SELECT 1 FROM track_corridor_snaps s
                  WHERE s.track_id = tracks.id AND (s.reverted_at IS NOT NULL OR #{STILL_SNAPPED_SQL}))
    SQL
  end

  def snap(track, trip, routes, dry_run)
    return Result.new(track_id: track.id, outcome: 'no real fixes') unless trip

    frame = G::Frame.new(*trip.lonlat.first)
    trip = trip.in_frame(frame)
    best = best_route(trip, routes, frame)
    unless best && best[:share] >= Corridors::Config.snap_share
      return Result.new(track_id: track.id, outcome: 'no route', share: best&.dig(:share)&.round(2))
    end

    stored = track.original_path.points.map { |p| frame.xy(p.x, p.y) }
    xy, middle = snapped_line(stored, best)
    result = { track_id: track.id, corridor_id: best[:corridor].id, share: best[:share].round(2) }
    return Result.new(**result, outcome: 'no route') unless xy
    # the route's part against the real fixes along it (the stored geometry
    # may have GPS spikes or a standing-still cloud, which the snap removes)
    return Result.new(**result, outcome: 'length off') unless LENGTH_RATIO.cover?(G.length(middle) / [best[:fixes_m], 1.0].max)

    write(track, xy.map { |x, y| frame.lonlat(x, y) }, G.length(xy), best) unless dry_run
    Result.new(**result, outcome: dry_run ? 'would snap' : 'snapped')
  end

  # The route of the trip's mode that holds the biggest share of its fixes
  # (of equal shares, the one they lie closer to).
  def best_route(trip, routes, frame)
    buffer = Corridors::Config.snap_buffer_m
    box = bbox(trip.lonlat, 0.0)
    routes.filter_map do |corridor, coords, corridor_box|
      next unless corridor.mode == trip.mode && overlap?(box, corridor_box)

      line = oriented(trip, coords.map { |lon, lat| frame.xy(lon, lat) })
      next unless line

      s = G.lengths(line)
      projected = G.project(line, s, trip.xy)
      inside = projected.each_index.select { |i| projected[i][1].abs <= buffer }
      next if inside.empty?

      { corridor:, line:, s:, share: inside.size.to_f / projected.size,
        offset: inside.sum { |i| projected[i][1].abs } / inside.size,
        fixes_m: G.length(trip.xy[inside.first..inside.last]) }
    end.max_by { |r| [r[:share], -r[:offset]] }
  end

  # The route as the trip runs it, or nil when the trip's ends are not near it.
  def oriented(trip, line)
    a, b = trip.xy.first, trip.xy.last
    near = ->(p) { line.any? { |q| G.dist(p, q) < ENDPOINT_M } }
    return nil unless near.(a) && near.(b)

    G.dist(a, line.first) + G.dist(b, line.last) <= G.dist(a, line.last) + G.dist(b, line.first) ? line : line.reverse
  end

  # [the stored geometry before it joins the route + the route + after it
  # leaves it, the route's part], or nil when it never comes within the buffer.
  def snapped_line(stored, best)
    buffer = Corridors::Config.snap_buffer_m
    projected = G.project(best[:line], best[:s], stored)
    inside = projected.each_index.select { |i| projected[i][1].abs <= buffer }
    return nil if inside.empty?

    first, last = inside.first, inside.last
    from, to = projected[first][0], projected[last][0]
    return nil unless to > from

    middle = G.slice(best[:line], best[:s], from, to)
    [stored[0...first] + middle + stored[(last + 1)..], middle]
  end

  # A candidate has no row yet, or Dawarich rebuilt it since its snap: either
  # way its geometry now is the one to record.
  def write(track, coords, length, best)
    wkt = "SRID=4326;LINESTRING(#{coords.map { |lon, lat| "#{lon.round(7)} #{lat.round(7)}" }.join(', ')})"
    TrackCorridorSnap.transaction do
      log = TrackCorridorSnap.find_or_initialize_by(track_id: track.id)
      log.assign_attributes(original_path: track.original_path, original_distance: track.distance,
                            original_avg_speed: track.avg_speed)
      now = Time.current
      track.update_columns(original_path: wkt, distance: length.round,
                           avg_speed: Track.avg_speed_kmh(length, track.duration), updated_at: now)
      log.update!(user_id: @user.id, corridor_id: best[:corridor].id, inside_share: best[:share], track_updated_at: now,
                  snapped_digest: Track.where(id: track.id).pick(Arel.sql(DIGEST_SQL)))
    end
    bump_tiles(track)
  end

  # [min lon, min lat, max lon, max lat] of [lon, lat] points, margin_m wider
  def bbox(coords, margin_m)
    lons = coords.map(&:first)
    lats = coords.map(&:last)
    dlat = margin_m / 110_540.0
    dlon = margin_m / (111_320.0 * Math.cos(lats.map(&:abs).max * Math::PI / 180).clamp(0.01, 1.0))
    [lons.min - dlon, lats.min - dlat, lons.max + dlon, lats.max + dlat]
  end

  def overlap?(a, b) = a[0] <= b[2] && b[0] <= a[2] && a[1] <= b[3] && b[1] <= a[3]

  def bump_tiles(track)
    Tracks::TileEpoch.bump(@user.id, timestamps: [track.start_at.to_i, track.end_at.to_i])
  rescue StandardError => e
    Rails.logger.warn("[corridors] tile epoch bump for track #{track.id} failed: #{e.class}: #{e.message}")
  end
end
