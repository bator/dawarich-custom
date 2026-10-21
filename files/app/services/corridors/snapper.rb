# frozen_string_literal: true

# Snaps a user's tracks onto their frequent routes (docs/corridors.md): a
# track of a route's mode whose real fixes lie within CORRIDORS_SNAP_BUFFER_M
# of the route for at least CORRIDORS_SNAP_SHARE of their number gets the
# route's line where its stored geometry runs along it; the stored parts
# before and after stay as they were. The geometry before the snap is kept in
# track_corridor_snaps for #revert, with a digest of the geometry written:
# while the track still has it, it is not snapped again; once Dawarich rebuilt
# the geometry (another digest), the new one is the recorded one. Tracks the
# OSRM snap already rewrote are left alone. Every track is measured in local
# metres around its own start (Geometry::Frame), so distances hold anywhere.
class Corridors::Snapper
  G = Corridors::Geometry
  ENDPOINT_M = 150.0
  LENGTH_RATIO = (0.75..1.33) # snapped vs stored length, else the match is suspicious
  DIGEST_SQL = 'md5(ST_AsBinary(tracks.original_path))'
  BATCH = 200 # tracks whose points are loaded at once

  Result = Struct.new(:track_id, :outcome, :corridor_id, :share, keyword_init: true)

  def initialize(user)
    @user = user
    @source = Corridors::TripSource.new(user)
  end

  # => [Result]; nothing is written when dry_run
  def call(since: 3.days.ago, dry_run: false)
    routes = TrackCorridor.where(user_id: @user.id).map { |c| [c, c.path.points.map { |p| [p.x, p.y] }] }
    return [] if routes.empty?

    candidates(since).to_a.each_slice(BATCH).flat_map do |tracks|
      trips = @source.trips_for(tracks.map(&:id))
      tracks.map { |track| snap(track, trips[track.id], routes, dry_run) }
    end
  end

  # Puts back the geometry of every snapped track that still has the snapped
  # one (a track Dawarich rebuilt since already has its recorded geometry).
  def revert(dry_run: false)
    logs = TrackCorridorSnap.where(user_id: @user.id).includes(:track).to_a
    digests = digests(logs.map(&:track_id))
    logs.map do |log|
      track = log.track
      unchanged = log.snapped_digest.present? && digests[track.id] == log.snapped_digest
      unless dry_run
        TrackCorridorSnap.transaction do
          if unchanged
            track.update_columns(original_path: log.original_path, distance: log.original_distance,
                                 avg_speed: log.original_avg_speed, updated_at: Time.current)
          end
          log.destroy!
        end
        bump_tiles(track)
      end
      Result.new(track_id: track.id, outcome: unchanged ? 'reverted' : 'rebuilt since, log dropped')
    end
  end

  private

  # Tracks of the routes' modes from the period, without the OSRM-snapped ones
  # and those that still have the geometry this snapper wrote.
  def candidates(since)
    scope = @user.tracks.where(dominant_mode: Corridors::Config.modes)
                 .where('tracks.start_at >= :since OR tracks.updated_at >= :since', since:)
    if ActiveRecord::Base.connection.table_exists?(:osrm_snap_log)
      scope = scope.where("NOT EXISTS (SELECT 1 FROM osrm_snap_log o WHERE o.track_id = tracks.id AND o.status = 'snapped')")
    end
    scope.where(<<~SQL.squish)
      NOT EXISTS (SELECT 1 FROM track_corridor_snaps s
                  WHERE s.track_id = tracks.id AND s.snapped_digest = #{DIGEST_SQL})
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
    xy = snapped_line(stored, best)
    result = { track_id: track.id, corridor_id: best[:corridor].id, share: best[:share].round(2) }
    return Result.new(**result, outcome: 'no route') unless xy

    length = G.length(xy)
    return Result.new(**result, outcome: 'length off') unless LENGTH_RATIO.cover?(length / [G.length(stored), 1.0].max)

    write(track, xy.map { |x, y| frame.lonlat(x, y) }, length, best) unless dry_run
    Result.new(**result, outcome: dry_run ? 'would snap' : 'snapped')
  end

  # The route of the trip's mode that holds the biggest share of its fixes.
  def best_route(trip, routes, frame)
    buffer = Corridors::Config.snap_buffer_m
    routes.filter_map do |corridor, coords|
      next unless corridor.mode == trip.mode

      line = oriented(trip, coords.map { |lon, lat| frame.xy(lon, lat) })
      next unless line

      s = G.lengths(line)
      projected = G.project(line, s, trip.xy)
      inside = projected.count { |_, offset| offset.abs <= buffer }
      { corridor:, line:, s:, share: inside.to_f / projected.size }
    end.max_by { |r| r[:share] }
  end

  # The route as the trip runs it, or nil when the trip's ends are not near it.
  def oriented(trip, line)
    a, b = trip.xy.first, trip.xy.last
    near = ->(p) { line.any? { |q| G.dist(p, q) < ENDPOINT_M } }
    return nil unless near.(a) && near.(b)

    G.dist(a, line.first) + G.dist(b, line.last) <= G.dist(a, line.last) + G.dist(b, line.first) ? line : line.reverse
  end

  # The stored geometry before it joins the route + the route + after it
  # leaves it, or nil when it never comes within the buffer.
  def snapped_line(stored, best)
    buffer = Corridors::Config.snap_buffer_m
    projected = G.project(best[:line], best[:s], stored)
    inside = projected.each_index.select { |i| projected[i][1].abs <= buffer }
    return nil if inside.empty?

    first, last = inside.first, inside.last
    from, to = projected[first][0], projected[last][0]
    return nil unless to > from

    stored[0...first] + G.slice(best[:line], best[:s], from, to) + stored[(last + 1)..]
  end

  def write(track, coords, length, best)
    wkt = "SRID=4326;LINESTRING(#{coords.map { |lon, lat| "#{lon.round(7)} #{lat.round(7)}" }.join(', ')})"
    TrackCorridorSnap.transaction do
      log = TrackCorridorSnap.find_or_initialize_by(track_id: track.id)
      # first snap, or Dawarich rebuilt the geometry since: the current one is the recorded one
      if log.new_record? || digests([track.id])[track.id] != log.snapped_digest
        log.assign_attributes(original_path: track.original_path, original_distance: track.distance,
                              original_avg_speed: track.avg_speed)
      end
      now = Time.current
      track.update_columns(original_path: wkt, distance: length.round,
                           avg_speed: Track.avg_speed_kmh(length, track.duration), updated_at: now)
      log.update!(user_id: @user.id, corridor_id: best[:corridor].id, inside_share: best[:share], track_updated_at: now,
                  snapped_digest: digests([track.id])[track.id])
    end
    bump_tiles(track)
  end

  # {track_id => digest of its stored geometry}
  def digests(track_ids)
    Track.where(id: track_ids).pluck(:id, Arel.sql(DIGEST_SQL)).to_h
  end

  def bump_tiles(track)
    Tracks::TileEpoch.bump(@user.id, timestamps: [track.start_at.to_i, track.end_at.to_i])
  rescue StandardError => e
    Rails.logger.warn("[corridors] tile epoch bump for track #{track.id} failed: #{e.class}: #{e.message}")
  end
end
