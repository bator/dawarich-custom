# frozen_string_literal: true

# What the Discord map image of one ride shows: the matched line between the
# boarding and alighting stop (the trip's shape, e.g. the pfaedle-matched MÁV
# railway; else the line through the timetable stops; else a straight line;
# for an older ride whose feed version has been replaced since, a trip of the
# active version through the same two stops stands in for its own trip),
# the GPS trace and the two stops. The trace is cut at every gap (no fix for
# a long stretch: the minutes before the phone's first fix, the M4
# underground, a station hall, or a position jump), so no straight line runs
# across where the ride never went (ride 111's trace drew one from
# Kelenföld towards Diósd), and a short piece (MIN_PIECE_SHARE) between two
# gaps is left out (with a fix every few minutes there is no trace at all,
# only chords). Nothing that lies in one of the user's privacy zones
# (plus ZONE_BUFFER_M) is returned: every edge of the lines and the trace is
# clipped exactly at the zone circle (review A1: an edge between two points
# outside a zone can still cross it), so they end at the buffered zone
# border, and a stop inside one is left out.
class Gtfs::Discord::RideMap
  EARTH_RADIUS_M = 6_371_000.0
  ZONE_BUFFER_M = 50.0 # the line stops a bit before the zone, not at its exact border
  EPSILON = 1e-9
  # A gap in the trace: a step longer than GAP_M, or longer than GAP_SLOW_M
  # after more than GAP_S without a fix. Phones sending every 1-5 s step at
  # most ~250 m between two fixes (99.9% of them; 160 km/h is 220 m in 5 s),
  # and the longer steps of a few seconds are fast rides with a fix or two
  # missed, whose chord stays on the track. A shorter step after a silence
  # is a gap too (bus 20: 833 m in 157 s), unless the phone barely moved, e.g.
  # standing at a station.
  GAP_M = 1_000.0
  GAP_S = 30
  GAP_SLOW_M = 250.0
  # A piece of trace shorter than this share of the ride (7-14 px on the
  # image, which fits the whole ride) or than MIN_PIECE_M is a stub, not a trace.
  MIN_PIECE_SHARE = 0.02
  MIN_PIECE_M = 50.0

  Result = Struct.new(:line, :line_source, :gps, :board, :alight, keyword_init: true) do
    delegate :empty?, to: :coordinates

    def coordinates
      line.flatten(1) + gps.flatten(1) + [board, alight].compact
    end
  end

  def initialize(segment, zones: nil)
    @segment = segment
    @zones = zones || Users::PrivacyZones.new(segment.user).call
  end

  def call
    source, coordinates = line_coordinates
    Result.new(line: runs(coordinates), line_source: source, gps: gps_pieces.flat_map { |piece| runs(piece) },
               board: visible(lonlat(@segment.boarding_lonlat)), alight: visible(lonlat(@segment.alighting_lonlat)))
  end

  private

  def line_coordinates
    own = [@segment.feed_version, @segment.trip_gtfs_id]
    shape = shape_coordinates(*own)
    return ['shape', shape] if shape.size >= 2

    current = current_trip
    shape = current ? shape_coordinates(*current) : []
    return ['shape', shape] if shape.size >= 2

    [own, current].compact.each do |version, trip|
      stops = stop_coordinates(version, trip)
      return ['stops', stops] if stops.size >= 2
    end

    ['straight', [lonlat(@segment.boarding_lonlat), lonlat(@segment.alighting_lonlat)].compact]
  end

  # [version, trip id] of a trip in the feed's active version that calls at the
  # boarding and then at the alighting stop (stop ids stay across versions):
  # one of the ride's route and with a shape first. Only asked for when the
  # ride's own trip has no shape, e.g. its feed version is gone since.
  def current_trip
    version = Gtfs::Feed.where(id: @segment.feed_id).pick(:active_version)
    return unless version && @segment.boarding_stop_gtfs_id && @segment.alighting_stop_gtfs_id

    sql = <<~SQL.squish
      SELECT gtfs_trips.gtfs_id
      FROM gtfs_stop_times board
      JOIN gtfs_stop_times alight ON alight.feed_id = board.feed_id AND alight.version = board.version
                                 AND alight.trip_gtfs_id = board.trip_gtfs_id AND alight.stop_sequence > board.stop_sequence
      JOIN gtfs_trips ON gtfs_trips.feed_id = board.feed_id AND gtfs_trips.version = board.version
                     AND gtfs_trips.gtfs_id = board.trip_gtfs_id
      WHERE board.feed_id = ? AND board.version = ? AND board.stop_gtfs_id = ? AND alight.stop_gtfs_id = ?
      ORDER BY gtfs_trips.route_gtfs_id IS DISTINCT FROM ?, gtfs_trips.shape_gtfs_id IS NULL
      LIMIT 1
    SQL
    # the same answer for every ride between these stops until the next feed
    # version, and the map of a ride is drawn again on every status change
    key = ['gtfs/ride_map/current_trip', @segment.feed_id, version, @segment.boarding_stop_gtfs_id,
           @segment.alighting_stop_gtfs_id, @segment.route_gtfs_id]
    trip = Rails.cache.fetch(key, expires_in: 1.day) do
      select_value(sql, @segment.feed_id, version, @segment.boarding_stop_gtfs_id,
                   @segment.alighting_stop_gtfs_id, @segment.route_gtfs_id)
    end
    [version, trip] if trip
  end

  # The trip's shape between the points closest to the two stops.
  def shape_coordinates(version, trip)
    board = lonlat(@segment.boarding_lonlat)
    alight = lonlat(@segment.alighting_lonlat)
    return [] unless board && alight && trip

    sql = <<~SQL.squish
      WITH shape AS (
        SELECT gtfs_shapes.path::geometry AS g
        FROM gtfs_trips
        JOIN gtfs_shapes ON gtfs_shapes.feed_id = gtfs_trips.feed_id AND gtfs_shapes.version = gtfs_trips.version
                        AND gtfs_shapes.gtfs_id = gtfs_trips.shape_gtfs_id
        WHERE gtfs_trips.feed_id = ? AND gtfs_trips.version = ? AND gtfs_trips.gtfs_id = ?
        LIMIT 1
      ), located AS (
        SELECT g, ST_LineLocatePoint(g, ST_SetSRID(ST_MakePoint(?, ?), 4326)) AS a,
                  ST_LineLocatePoint(g, ST_SetSRID(ST_MakePoint(?, ?), 4326)) AS b
        FROM shape
      )
      SELECT ST_AsGeoJSON(ST_LineSubstring(g, LEAST(a, b), GREATEST(a, b)), 6) FROM located WHERE a <> b
    SQL
    json = select_value(sql, @segment.feed_id, version, trip, *board, *alight)
    json ? Array(JSON.parse(json)['coordinates']) : []
  end

  # The timetable stops from the boarding to the alighting stop.
  def stop_coordinates(version, trip)
    return [] unless trip

    sql = <<~SQL.squish
      SELECT gtfs_stop_times.stop_gtfs_id, ST_X(gtfs_stops.lonlat::geometry), ST_Y(gtfs_stops.lonlat::geometry)
      FROM gtfs_stop_times
      JOIN gtfs_stops ON gtfs_stops.feed_id = gtfs_stop_times.feed_id AND gtfs_stops.version = gtfs_stop_times.version
                     AND gtfs_stops.gtfs_id = gtfs_stop_times.stop_gtfs_id
      WHERE gtfs_stop_times.feed_id = ? AND gtfs_stop_times.version = ? AND gtfs_stop_times.trip_gtfs_id = ?
      ORDER BY gtfs_stop_times.stop_sequence
    SQL
    rows = select_rows(sql, @segment.feed_id, version, trip)
    from = rows.index { |row| row[0] == @segment.boarding_stop_gtfs_id }
    to = from && rows.each_index.find { |i| i > from && rows[i][0] == @segment.alighting_stop_gtfs_id }
    return [] unless to

    rows[from..to].map { |row| [row[1].to_f, row[2].to_f] }
  end

  # The trace between its gaps, each piece a list of coordinates, without the
  # short pieces (a lone fix is one too).
  def gps_pieces
    shortest = [@segment.distance_m.to_f * MIN_PIECE_SHARE, MIN_PIECE_M].max
    gps_points.slice_when { |a, b| gap?(a, b) }
              .map { |piece| piece.map { |lon, lat, _| [lon, lat] } }
              .select { |piece| piece.each_cons(2).sum { |a, b| distance_m(a, b) } >= shortest }
  end

  def gap?((lon0, lat0, time0), (lon1, lat1, time1))
    step = distance_m([lon0, lat0], [lon1, lat1])
    step > GAP_M || (time1 - time0 > GAP_S && step > GAP_SLOW_M)
  end

  # Read only: the ride's points, oldest first, as [lon, lat, unix time].
  def gps_points
    sql = <<~SQL.squish
      SELECT ST_X(points.lonlat::geometry), ST_Y(points.lonlat::geometry), points.timestamp
      FROM transit_segment_points
      JOIN points ON points.id = transit_segment_points.point_id
      WHERE transit_segment_points.transit_segment_id = ? AND points.lonlat IS NOT NULL
      ORDER BY points.timestamp, points.id
    SQL
    select_rows(sql, @segment.id).map { |lon, lat, time| [lon.to_f, lat.to_f, time.to_i] }
  end

  # Metres between two coordinates (equirectangular: exact enough for a step).
  def distance_m((lon0, lat0), (lon1, lat1))
    rad = Math::PI / 180
    Math.hypot((lon1 - lon0) * rad * Math.cos((lat0 + lat1) / 2 * rad), (lat1 - lat0) * rad) * EARTH_RADIUS_M
  end

  # The visible parts of a polyline, each a list of coordinates.
  def runs(coordinates)
    return coordinates.reject { |c| in_zone?(c) }.map { |c| [c] } if coordinates.size < 2

    result = []
    current = []
    coordinates.each_cons(2) do |a, b|
      intervals = visible_intervals(a, b)
      intervals.each do |t0, t1|
        if t0 <= EPSILON && current.any?
          current << point_at(a, b, t1)
        else
          result << current if current.size >= 2
          current = [point_at(a, b, t0), point_at(a, b, t1)]
        end
      end
      next if intervals.any? && intervals.last[1] >= 1 - EPSILON

      result << current if current.size >= 2
      current = []
    end
    result << current if current.size >= 2
    result
  end

  # Parts [t0, t1] of the edge from->to (t in 0..1) outside every zone.
  def visible_intervals(from, to)
    hidden = @zones.filter_map { |zone| hidden_interval(from, to, zone) }.sort
    visible = []
    from = 0.0
    hidden.each do |t0, t1|
      visible << [from, t0] if t0 - from > EPSILON
      from = [from, t1].max
    end
    visible << [from, 1.0] if 1.0 - from > EPSILON
    visible
  end

  # Where the edge runs inside the (buffered) zone circle, in a local metric
  # projection around the zone centre: |a + t (b - a)| <= r.
  def hidden_interval(from, to, zone)
    ax, ay = local_xy(from, zone)
    bx, by = local_xy(to, zone)
    dx = bx - ax
    dy = by - ay
    radius = zone[:radius].to_f + ZONE_BUFFER_M
    qa = (dx * dx) + (dy * dy)
    qc = (ax * ax) + (ay * ay) - (radius * radius)
    return (qc <= 0 ? [0.0, 1.0] : nil) if qa < EPSILON

    qb = 2 * ((ax * dx) + (ay * dy))
    disc = (qb * qb) - (4 * qa * qc)
    return nil if disc.negative?

    root = Math.sqrt(disc)
    t0 = [(-qb - root) / (2 * qa), 0.0].max
    t1 = [(-qb + root) / (2 * qa), 1.0].min
    t1 - t0 > EPSILON ? [t0, t1] : nil
  end

  def local_xy(coordinate, zone)
    lon, lat = coordinate
    lat0 = zone[:lat].to_f
    rad = Math::PI / 180
    [(lon - zone[:lon].to_f) * rad * EARTH_RADIUS_M * Math.cos(lat0 * rad), (lat - lat0) * rad * EARTH_RADIUS_M]
  end

  def point_at(from, to, frac)
    return from if frac <= EPSILON
    return to if frac >= 1 - EPSILON

    [from[0] + ((to[0] - from[0]) * frac), from[1] + ((to[1] - from[1]) * frac)]
  end

  def visible(coordinate)
    coordinate unless coordinate.nil? || in_zone?(coordinate)
  end

  def in_zone?(coordinate)
    @zones.any? do |zone|
      x, y = local_xy(coordinate, zone)
      Math.hypot(x, y) <= zone[:radius].to_f + ZONE_BUFFER_M
    end
  end

  def lonlat(point)
    point && [point.x.to_f, point.y.to_f]
  end

  def select_value(sql, *binds)
    TransitSegment.connection.select_value(TransitSegment.sanitize_sql_array([sql, *binds]))
  end

  def select_rows(sql, *binds)
    TransitSegment.connection.select_rows(TransitSegment.sanitize_sql_array([sql, *binds]))
  end
end
