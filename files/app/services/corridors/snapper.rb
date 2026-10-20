# frozen_string_literal: true

# Snaps a user's tracks onto their frequent routes (docs/corridors.md): a
# track of a route's mode whose real fixes lie within CORRIDORS_SNAP_BUFFER_M
# of the route for at least CORRIDORS_SNAP_SHARE of their number gets the
# route's line between where it joins and leaves it (the recorded parts before
# and after stay). The geometry before the snap is kept in
# track_corridor_snaps for #revert. Tracks the OSRM snap already rewrote are
# left alone, and a track is snapped again only after Dawarich rebuilt it.
class Corridors::Snapper
  G = Corridors::Geometry
  ENDPOINT_M = 150.0
  LENGTH_RATIO = (0.75..1.33) # snapped vs recorded length, else the match is suspicious

  Result = Struct.new(:track_id, :outcome, :corridor_id, :share, keyword_init: true)

  def initialize(user)
    @user = user
    @source = Corridors::TripSource.new(user)
    @frame = @source.frame
  end

  # => [Result]; nothing is written when dry_run
  def call(since: 3.days.ago, dry_run: false)
    routes = TrackCorridor.where(user_id: @user.id).map do |c|
      line = c.path.points.map { |p| @frame.xy(p.x, p.y) }
      [c, line, G.lengths(line)]
    end
    return [] if routes.empty?

    candidates(since).map { |track| snap(track, routes, dry_run) }
  end

  # Puts back the geometry of every snapped track that Dawarich did not
  # rebuild since (those already have their recorded geometry again).
  def revert(dry_run: false)
    TrackCorridorSnap.where(user_id: @user.id).includes(:track).map do |log|
      track = log.track
      unchanged = track.updated_at.to_i == log.track_updated_at.to_i
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

  def candidates(since)
    scope = @user.tracks.where(dominant_mode: Corridors::Config.modes)
                 .where('tracks.start_at >= :since OR tracks.updated_at >= :since', since:)
    if ActiveRecord::Base.connection.table_exists?(:osrm_snap_log)
      scope = scope.where("NOT EXISTS (SELECT 1 FROM osrm_snap_log o WHERE o.track_id = tracks.id AND o.status = 'snapped')")
    end
    scope.where(<<~SQL.squish)
      NOT EXISTS (SELECT 1 FROM track_corridor_snaps s
                  WHERE s.track_id = tracks.id AND date_trunc('second', s.track_updated_at) = date_trunc('second', tracks.updated_at))
    SQL
  end

  def snap(track, routes, dry_run)
    trip = @source.trip(track)
    return Result.new(track_id: track.id, outcome: 'no real fixes') unless trip

    best = best_route(trip, routes)
    unless best && best[:share] >= Corridors::Config.snap_share
      return Result.new(track_id: track.id, outcome: 'no route', share: best&.dig(:share)&.round(2))
    end

    xy = snapped_line(trip.xy, best)
    length = G.length(xy)
    recorded = G.length(trip.xy)
    unless LENGTH_RATIO.cover?(length / recorded)
      return Result.new(track_id: track.id, outcome: 'length off', corridor_id: best[:corridor].id, share: best[:share].round(2))
    end

    write(track, xy, length, best) unless dry_run
    Result.new(track_id: track.id, outcome: dry_run ? 'would snap' : 'snapped', corridor_id: best[:corridor].id,
               share: best[:share].round(2))
  end

  # The route of the trip's mode that holds the biggest share of its fixes.
  def best_route(trip, routes)
    buffer = Corridors::Config.snap_buffer_m
    routes.filter_map do |corridor, line, s|
      next unless corridor.mode == trip.mode

      line, s = reverse_if_needed(trip, line, s)
      next unless line

      projected = G.project(line, s, trip.xy)
      inside = projected.count { |_, offset| offset.abs <= buffer }
      { corridor:, line:, s:, projected:, share: inside.to_f / projected.size }
    end.max_by { |r| r[:share] }
  end

  # The route as the trip runs it, or nil when the trip's ends are not near it.
  def reverse_if_needed(trip, line, s)
    a, b = trip.xy.first, trip.xy.last
    near = ->(p) { line.any? { |q| G.dist(p, q) < ENDPOINT_M } }
    return [nil, nil] unless near.(a) && near.(b)

    forward = G.dist(a, line.first) + G.dist(b, line.last)
    backward = G.dist(a, line.last) + G.dist(b, line.first)
    return [line, s] if forward <= backward

    reversed = line.reverse
    [reversed, G.lengths(reversed)]
  end

  # recorded fixes before the trip joins the route + the route + after it leaves
  def snapped_line(trip_xy, best)
    buffer = Corridors::Config.snap_buffer_m
    inside = best[:projected].each_index.select { |i| best[:projected][i][1].abs <= buffer }
    first, last = inside.first, inside.last
    from, to = best[:projected][first][0], best[:projected][last][0]
    line, s = best[:line], best[:s]
    middle = [point_at(line, s, from)] + line.each_index.select { |i| s[i] > from && s[i] < to }.map { |i| line[i] } +
             [point_at(line, s, to)]
    trip_xy[0...first] + middle + trip_xy[(last + 1)..]
  end

  def point_at(line, s, station)
    i = (G.bsearch_index(s, station) - 1).clamp(0, line.size - 2)
    span = s[i + 1] - s[i]
    f = span.positive? ? ((station - s[i]) / span).clamp(0.0, 1.0) : 0.0
    a, b = line[i], line[i + 1]
    [a[0] + ((b[0] - a[0]) * f), a[1] + ((b[1] - a[1]) * f)]
  end

  def write(track, xy, length, best)
    coords = xy.map { |x, y| @frame.lonlat(x, y) }
    wkt = "SRID=4326;LINESTRING(#{coords.map { |lon, lat| "#{lon.round(7)} #{lat.round(7)}" }.join(', ')})"
    TrackCorridorSnap.transaction do
      log = TrackCorridorSnap.find_or_initialize_by(track_id: track.id)
      # first snap, or Dawarich rebuilt the track since: its geometry now is the recorded one
      if log.new_record? || log.track_updated_at.to_i != track.updated_at.to_i
        log.assign_attributes(original_path: track.original_path, original_distance: track.distance,
                              original_avg_speed: track.avg_speed)
      end
      now = Time.current
      track.update_columns(original_path: wkt, distance: length.round,
                           avg_speed: Track.avg_speed_kmh(length, track.duration), updated_at: now)
      log.update!(user_id: @user.id, corridor_id: best[:corridor].id, inside_share: best[:share], track_updated_at: now)
    end
    bump_tiles(track)
  end

  def bump_tiles(track)
    Tracks::TileEpoch.bump(@user.id, timestamps: [track.start_at.to_i, track.end_at.to_i])
  rescue StandardError => e
    Rails.logger.warn("[corridors] tile epoch bump for track #{track.id} failed: #{e.class}: #{e.message}")
  end
end
