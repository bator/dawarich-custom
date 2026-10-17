# frozen_string_literal: true

# Spec 9.3: candidate trips for one window, one feed version and one service
# date. A trip qualifies when it runs on the service date, calls at a stop
# near the window start before a stop near the window end (stop_sequence
# order, so loop lines work, 17.7), and departs/arrives within
# TIME_TOLERANCE_SECS of the window start/end. Only read queries.
class Gtfs::Matching::CandidateFinder
  Candidate = Struct.new(
    :feed, :version, :service_date, :day_start, :trip_gtfs_id, :board_stop_gtfs_id, :alight_stop_gtfs_id,
    :board_secs, :alight_secs, :board_seq, :alight_seq, :residual, keyword_init: true
  )

  ROW_LIMIT = 5000 # closest rows first (review A1), so a cut is deterministic

  def initialize(feed:, version:, service_date:, privacy_zones: [])
    @feed = feed
    @version = version
    @service_date = service_date
    @privacy_zones = privacy_zones
    @day_start = Gtfs::ServiceCalendar.service_day_start(service_date, feed.time_zone)
  end

  # board_points / alight_points: MatchPoint lists around the window ends
  def call(window, board_points:, alight_points:)
    board_ids = stops_near(board_points)
    alight_ids = stops_near(alight_points)
    return [] if board_ids.empty? || alight_ids.empty?

    t_start = window.start_ts - @day_start.to_i
    t_end = window.end_ts - @day_start.to_i
    best_pair_per_trip(query(board_ids, alight_ids, t_start, t_end), t_start, t_end)
      .min_by(Gtfs::Config::MAX_CANDIDATES, &:residual)
  end

  # Stop ids within BOARD_RADIUS_M (railway stations: RAIL_BOARD_RADIUS_M)
  # of any of the points, including the other platforms of the same station
  # (parent_station, 17.6). Stops inside a privacy zone are never used.
  def stops_near(points)
    return [] if points.empty?

    radius = [Gtfs::Config::BOARD_RADIUS_M, Gtfs::Config::RAIL_BOARD_RADIUS_M].max
    # one condition for all points (review A7): their multipoint, then the
    # exact radius per stop below
    multipoint = "MULTIPOINT(#{points.map { |p| "#{p.lon.to_f} #{p.lat.to_f}" }.join(', ')})"
    rows = Gtfs::Stop.where(feed_id: @feed.id, version: @version)
                     .where('ST_DWithin(lonlat, ST_GeomFromText(?, 4326)::geography, ?)', multipoint, radius)
                     .pluck(:gtfs_id, :location_type, :parent_station_gtfs_id,
                            Arel.sql('ST_X(lonlat::geometry)'), Arel.sql('ST_Y(lonlat::geometry)'))
    rows = rows.select { |id, _, _, lon, lat| within_radius?(id, lon, lat, points) }
    rows = rows.reject { |_, _, _, lon, lat| Gtfs::Matching::PointLoader.in_zones?(lon, lat, @privacy_zones) }
    stations = rows.filter_map { |id, type, parent| type == 1 ? id : parent }.uniq
    ids = rows.map(&:first)
    if stations.any?
      ids += Gtfs::Stop.where(feed_id: @feed.id, version: @version, parent_station_gtfs_id: stations)
                       .pluck(:gtfs_id, Arel.sql('ST_X(lonlat::geometry)'), Arel.sql('ST_Y(lonlat::geometry)'))
                       .reject { |_, lon, lat| Gtfs::Matching::PointLoader.in_zones?(lon, lat, @privacy_zones) }
                       .map(&:first)
    end
    ids.uniq
  end

  # Shared by Sidekiq threads (review A6).
  RAIL_STOP_CACHE = Concurrent::Map.new
  RAIL_STOP_CACHE_SIZE = 50

  # Stop ids served by railway routes in this feed version (cached per
  # process; versions never change after import). Feeds without any railway
  # route are answered from gtfs_routes alone, without the stop_times join.
  def self.rail_stop_ids(feed_id, version)
    RAIL_STOP_CACHE.clear if RAIL_STOP_CACHE.size > RAIL_STOP_CACHE_SIZE
    RAIL_STOP_CACHE.compute_if_absent([feed_id, version]) { load_rail_stop_ids(feed_id, version) }
  end

  def self.load_rail_stop_ids(feed_id, version)
    rail_types = Gtfs::Config::RAIL_ROUTE_TYPES
    return Set.new unless Gtfs::Route.exists?(feed_id:, version:, route_type: rail_types)

    Gtfs::StopTime.joins(<<~SQL.squish)
      JOIN gtfs_trips tr ON tr.feed_id = gtfs_stop_times.feed_id AND tr.version = gtfs_stop_times.version
                        AND tr.gtfs_id = gtfs_stop_times.trip_gtfs_id
      JOIN gtfs_routes r ON r.feed_id = tr.feed_id AND r.version = tr.version AND r.gtfs_id = tr.route_gtfs_id
    SQL
                  .where(feed_id:, version:).where(r: { route_type: rail_types })
                  .distinct.pluck(:stop_gtfs_id).to_set
  end

  private

  def within_radius?(stop_id, lon, lat, points)
    distance = points.map { |p| Gtfs::Matching::Geo.haversine(p.lon, p.lat, lon, lat) }.min
    return true if distance <= Gtfs::Config::BOARD_RADIUS_M

    distance <= Gtfs::Config::RAIL_BOARD_RADIUS_M && self.class.rail_stop_ids(@feed.id, @version).include?(stop_id)
  end

  def query(board_ids, alight_ids, t_start, t_end)
    tol = Gtfs::Config::TIME_TOLERANCE_SECS
    binds = {
      feed_id: @feed.id, version: @version, service_date: @service_date,
      board_ids:, alight_ids:,
      start_min: t_start - tol, start_max: t_start + tol,
      end_min: t_end - tol, end_max: t_end + tol, t_start:, t_end:,
      limit: ROW_LIMIT
    }
    sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, binds])
      SELECT st_b.trip_gtfs_id, st_b.stop_gtfs_id, st_a.stop_gtfs_id, st_b.departure_secs, st_a.arrival_secs,
             st_b.stop_sequence, st_a.stop_sequence
      FROM gtfs_stop_times st_b
      JOIN gtfs_stop_times st_a
        ON st_a.feed_id = st_b.feed_id AND st_a.version = st_b.version
       AND st_a.trip_gtfs_id = st_b.trip_gtfs_id AND st_a.stop_sequence > st_b.stop_sequence
      JOIN gtfs_trips tr
        ON tr.feed_id = st_b.feed_id AND tr.version = st_b.version AND tr.gtfs_id = st_b.trip_gtfs_id
      JOIN gtfs_service_days sd
        ON sd.feed_id = tr.feed_id AND sd.version = tr.version
       AND sd.service_gtfs_id = tr.service_gtfs_id AND sd.service_date = :service_date
      WHERE st_b.feed_id = :feed_id AND st_b.version = :version
        AND tr.times_valid
        AND st_b.stop_gtfs_id IN (:board_ids)
        AND st_a.stop_gtfs_id IN (:alight_ids)
        AND st_b.departure_secs BETWEEN :start_min AND :start_max
        AND st_a.arrival_secs BETWEEN :end_min AND :end_max
      ORDER BY abs(st_b.departure_secs - :t_start) + abs(st_a.arrival_secs - :t_end),
               st_b.trip_gtfs_id, st_b.stop_sequence, st_a.stop_sequence
      LIMIT :limit
    SQL
    ActiveRecord::Base.connection.select_rows(sql)
  end

  def best_pair_per_trip(rows, t_start, t_end)
    rows.group_by(&:first).map do |trip_id, pairs|
      board, alight, board_secs, alight_secs, board_seq, alight_seq =
        pairs.min_by { |r| (r[3] - t_start).abs + (r[4] - t_end).abs }.drop(1)
      Candidate.new(
        feed: @feed, version: @version, service_date: @service_date, day_start: @day_start,
        trip_gtfs_id: trip_id, board_stop_gtfs_id: board, alight_stop_gtfs_id: alight,
        board_secs:, alight_secs:, board_seq:, alight_seq:,
        residual: (board_secs - t_start).abs + (alight_secs - t_end).abs
      )
    end
  end
end
