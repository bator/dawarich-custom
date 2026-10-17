# frozen_string_literal: true

# JSON of a transit segment for the API, the web list and the map (spec 11).
# Coordinates are [lon, lat] (GeoJSON order).
class Api::TransitSegmentSerializer
  # Used when the route is not in the timetable any more (spec 12.2).
  DEFAULT_COLORS = Gtfs::RouteColors::MODE_DEFAULTS

  # line colours of many segments in one query (Gtfs::RouteColors: the
  # operator's colours): {[feed_id, route_gtfs_id] => [color, text_color]}
  def self.colors_for(segments)
    Gtfs::RouteColors.for_segments(segments).transform_values { |c| [c.color, c.text_color] }
  end

  def initialize(segment, colors: {}, detail: false)
    @segment = segment
    @colors = colors
    @detail = detail
  end

  def call
    s = @segment
    color, text_color = @colors[[s.feed_id, s.route_gtfs_id]]
    color = hex(color) || DEFAULT_COLORS.fetch(s.mode)
    data = {
      id: s.id,
      route_short_name: s.route_short_name,
      route_long_name: s.route_long_name,
      route_type: s.route_type,
      mode: s.mode,
      route_color: color,
      route_text_color: hex(text_color) || '#FFFFFF',
      route_casing_color: Gtfs::RouteColors.casing(color),
      headsign: s.headsign,
      boarding_stop: stop(s.boarding_stop_gtfs_id, s.boarding_stop_name, s.boarding_lonlat),
      alighting_stop: stop(s.alighting_stop_gtfs_id, s.alighting_stop_name, s.alighting_lonlat),
      started_at: s.started_at,
      ended_at: s.ended_at,
      duration_s: s.ended_at - s.started_at,
      distance_m: s.distance_m&.round(1),
      confidence: s.confidence.round(3),
      status: s.status,
      uncertain: s.uncertain?,
      # drawn dashed (same threshold as the Discord image)
      display_uncertain: Gtfs::Discord::Config.show_uncertain?(s),
      delay_secs: s.delay_reliable? ? s.debug['delay_secs'] : nil,
      feed: s.feed&.key,
      trip_gtfs_id: s.trip_gtfs_id,
      service_date: s.debug&.dig('service_date')
    }
    @detail ? data.merge(details) : data
  end

  private

  def details
    debug = @segment.debug || {}
    {
      point_ids: @segment.transit_segment_points.order(:point_id).pluck(:point_id),
      point_count: @segment.point_count,
      scheduled_departure_secs: debug['scheduled_departure_secs'],
      scheduled_arrival_secs: debug['scheduled_arrival_secs'],
      estimated_delay_secs: debug['delay_secs'],
      ambiguous: debug['ambiguous'] == true,
      trip_ambiguous: debug['trip_ambiguous'] == true,
      caps: Array(debug['caps']),
      features: debug['features'] || {},
      alternatives: alternatives(debug)
    }
  end

  def alternatives(debug)
    (Array(debug['alternatives']) + Array(debug['trip_alternatives'])).map do |alt|
      {
        feed_id: alt['feed_id'], trip_gtfs_id: alt['trip_gtfs_id'], line: alt['line'] || alt['route_short_name'],
        confidence: alt['confidence'], boarding_stop_name: alt['boarding_stop_name'],
        alighting_stop_name: alt['alighting_stop_name'], started_at: alt['started_at'], ended_at: alt['ended_at'],
        delay_secs: alt['delay_secs'], choosable: alt.key?('started_at')
      }
    end
  end

  def stop(id, name, lonlat)
    { id:, name:, coordinates: lonlat && [lonlat.lon.round(6), lonlat.lat.round(6)] }
  end

  def hex(value)
    value = value.to_s.delete_prefix('#')
    value.match?(/\A\h{6}\z/) ? "##{value.upcase}" : nil
  end
end
