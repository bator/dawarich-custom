# frozen_string_literal: true

# Spec 9.5: the geometry and timetable of one trip, in a form the scorer can
# use: the shape as a projected polyline, every stop's distance along it and
# the schedule as a (time, distance) curve.
#
# - Stop distances come from projecting each stop onto the shape, searching
#   forward from the previous stop, so loop lines (same stop twice, 17.7)
#   and out-and-back shapes resolve in stop_sequence order.
# - Without a usable shape (shapes not imported, missing, or far from the
#   stops) the straight lines between the stops are used instead.
class Gtfs::Matching::TripProfile
  StopCall = Struct.new(:sequence, :stop_gtfs_id, :name, :parent_station_gtfs_id, :lon, :lat,
                        :arrival_secs, :departure_secs, :along, keyword_init: true)

  SHAPE_STOP_MAX_DISTANCE = 300 # metres; a farther stop means the shape does not fit the trip

  attr_reader :trip, :route, :stops, :polyline, :shape_source, :projector

  # Loads (and caches per run) the profile of a trip.
  def self.load(feed, version, trip_gtfs_id, cache: {})
    cache.fetch([feed.id, version, trip_gtfs_id]) do
      cache[[feed.id, version, trip_gtfs_id]] = new(feed, version, trip_gtfs_id, shape_cache: cache)
    end
  end

  def initialize(feed, version, trip_gtfs_id, shape_cache: {})
    @feed = feed
    @version = version
    @trip = Gtfs::Trip.find_by(feed_id: feed.id, version:, gtfs_id: trip_gtfs_id)
    @route = @trip && Gtfs::Route.find_by(feed_id: feed.id, version:, gtfs_id: @trip.route_gtfs_id)
    @stops = load_stops(trip_gtfs_id)
    @shape_cache = shape_cache
    build_geometry
  end

  def usable?
    @trip.present? && @stops.size >= 2 && @polyline&.usable?
  end

  def stop_at(sequence)
    @stops.find { |s| s.sequence == sequence }
  end

  # Projects a lon/lat onto the trip geometry within [from, to] along metres.
  def project(lon, lat, from: 0.0, to: Float::INFINITY)
    x, y = @projector.call(lon, lat)
    @polyline.project(x, y, from:, to:)
  end

  # Scheduled time interval [earliest, latest] (seconds of the service day)
  # at which the vehicle is at `along` metres, between two stop calls.
  def scheduled_interval(along, board, alight)
    calls = @stops.select { |s| s.sequence.between?(board.sequence, alight.sequence) }
    return [board.departure_secs, board.departure_secs] if along <= calls.first.along

    calls.each_cons(2) do |a, b|
      next if along > b.along

      return [b.arrival_secs, b.departure_secs] if (along - b.along).abs < 1e-6

      span = b.along - a.along
      return [a.departure_secs, a.departure_secs] unless span.positive?

      t = a.departure_secs + ((along - a.along) / span * (b.arrival_secs - a.departure_secs))
      return [t, t]
    end
    [alight.arrival_secs, alight.arrival_secs]
  end

  # Line label shown to the user: short name, else long name, else the trip
  # short name (MÁV train number, 17.9).
  def line_name
    @route&.short_name.presence || @route&.long_name.presence || @trip&.short_name.presence
  end

  # Station name for a stop call (17.6: show the parent station, not the platform).
  def display_name(call)
    return call.name if call.parent_station_gtfs_id.blank?

    @parent_names ||= {}
    @parent_names.fetch(call.parent_station_gtfs_id) do
      @parent_names[call.parent_station_gtfs_id] =
        Gtfs::Stop.where(feed_id: @feed.id, version: @version, gtfs_id: call.parent_station_gtfs_id)
                  .pick(:name).presence || call.name
    end
  end

  private

  def load_stops(trip_gtfs_id)
    rows = Gtfs::StopTime.joins(<<~SQL.squish)
      JOIN gtfs_stops s ON s.feed_id = gtfs_stop_times.feed_id AND s.version = gtfs_stop_times.version
                       AND s.gtfs_id = gtfs_stop_times.stop_gtfs_id
    SQL
                         .where(feed_id: @feed.id, version: @version, trip_gtfs_id:)
                         .order(:stop_sequence)
                         .pluck(:stop_sequence, :stop_gtfs_id, 's.name', 's.parent_station_gtfs_id',
                                Arel.sql('ST_X(s.lonlat::geometry)'), Arel.sql('ST_Y(s.lonlat::geometry)'),
                                :arrival_secs, :departure_secs)
    rows.map do |seq, stop_id, name, parent, lon, lat, arr, dep|
      StopCall.new(sequence: seq, stop_gtfs_id: stop_id, name:, parent_station_gtfs_id: parent, lon:, lat:,
                   arrival_secs: arr || dep, departure_secs: dep || arr)
    end
  end

  def build_geometry
    return if @stops.size < 2

    ref_lat = @stops.sum(&:lat) / @stops.size
    @projector = Gtfs::Matching::Geo.projector(ref_lat)
    shape = shape_coordinates
    if shape && assign_stop_distances(Gtfs::Matching::Geo::Polyline.new(shape, @projector))
      @shape_source = 'shape'
      return
    end

    @polyline = Gtfs::Matching::Geo::Polyline.new(@stops.map { |s| [s.lon, s.lat] }, @projector)
    @shape_source = 'stops'
    # same metric as the polyline (projected plane), duplicate positions add 0
    along = 0.0
    previous = nil
    @stops.each do |stop|
      xy = @projector.call(stop.lon, stop.lat)
      along += Math.hypot(xy[0] - previous[0], xy[1] - previous[1]) if previous
      stop.along = along
      previous = xy
    end
  end

  def shape_coordinates
    return nil if @trip&.shape_gtfs_id.blank?

    key = [:shape, @feed.id, @version, @trip.shape_gtfs_id]
    @shape_cache.fetch(key) do
      wkt = Gtfs::Shape.where(feed_id: @feed.id, version: @version, gtfs_id: @trip.shape_gtfs_id)
                       .pick(Arel.sql('ST_AsText(path::geometry)'))
      @shape_cache[key] = wkt && parse_linestring(wkt)
    end
  end

  def parse_linestring(wkt)
    body = wkt[/\(([^()]*)\)/, 1]
    return nil if body.nil?

    body.split(',').map { |pair| pair.strip.split.first(2).map(&:to_f) }
  end

  # Forward search of each stop on the shape; false if the shape does not fit.
  def assign_stop_distances(polyline)
    return false unless polyline.usable?

    previous = 0.0
    @stops.each_with_index do |stop, i|
      x, y = @projector.call(stop.lon, stop.lat)
      reach = if i.zero?
                polyline.length
              else
                prev = @stops[i - 1]
                (Gtfs::Matching::Geo.haversine(prev.lon, prev.lat, stop.lon, stop.lat) * 3) + 1000
              end
      along, distance = polyline.project(x, y, from: [previous - 50, 0].max, to: previous + reach)
      return false if along.nil? || distance > SHAPE_STOP_MAX_DISTANCE

      along = [along, previous].max
      stop.along = along
      previous = along
    end
    @polyline = polyline
    true
  end
end
