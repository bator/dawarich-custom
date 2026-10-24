# frozen_string_literal: true

# Reads for the Phase 3 API, web list and map. Everything starts from
# TransitSegment.visible_for, so privacy zones, opt-out, feed selection,
# rejected rides and rides without points are handled in one place.
class Gtfs::SegmentQuery
  class InvalidParams < StandardError; end

  MAX_PER_PAGE = 100
  DEFAULT_PER_PAGE = 50
  MAX_MAP_SEGMENTS = 500
  SIMPLIFY_DEGREES = 0.00002 # ~2 m; keeps the line shape, drops GPS jitter
  # RideMap line sources drawn on the map instead of the GPS points
  TIMETABLE_SOURCES = %w[shape stops].freeze
  GEOMETRY_VERSION = 1 # bump when the drawn line changes

  attr_reader :user

  # zones: the user's privacy zones when the caller has them already. A
  # positional argument, not a keyword: callers pass params as a bare hash
  # (`new(user, start_at: ...)`), which a keyword parameter would take over.
  def initialize(user, params = {}, zones = nil)
    @user = user
    @params = params.to_h.with_indifferent_access
    @zones = zones || Users::PrivacyZones.new(user).call
  end

  def scope
    rel = TransitSegment.visible_for(user, zones: @zones, min_confidence: min_confidence).includes(:feed)
    rel = rel.where(started_at: start_at..) if start_at
    rel = rel.where(started_at: ..end_at) if end_at
    rel = rel.where(status: status_filter) if status_filter
    rel.order(started_at: :desc, id: :desc)
  end

  def page
    integer_param(:page, 1, 1..)
  end

  def per_page
    integer_param(:per_page, DEFAULT_PER_PAGE, 1..).clamp(1, MAX_PER_PAGE)
  end

  def paginated
    scope.offset((page - 1) * per_page).limit(per_page)
  end

  def total
    scope.count
  end

  # GeoJSON line of each ride for the map: the timetable's line between the
  # boarding and the alighting stop (Gtfs::Discord::RideMap: the trip's shape,
  # e.g. the pfaedle-matched MÁV railway, else the line through the timetable
  # stops), as the Discord image draws it, clipped at the privacy zones.
  # Until 2026-10-24 the map drew the ride's GPS points, a straight line across
  # every stretch without a usable fix (G44, 2026-10-23: 4.4 km straight into
  # Székesfehérvár, off the railway's curve; Bator). A ride whose timetable
  # line is only a straight line between the two stops keeps its GPS points
  # (ride_point_lines). Cached per ride and its last change.
  def geometries(segment_ids)
    return {} if segment_ids.empty?

    segments = TransitSegment.where(id: segment_ids).to_a
    timetable = segments.to_h { |s| [s.id, timetable_line(s)] }.compact
    gps_ids = segment_ids - timetable.keys
    timetable.merge(ride_point_lines(gps_ids))
  end

  private

  def timetable_line(segment)
    key = ['gtfs/ride_line', GEOMETRY_VERSION, segment.id, segment.updated_at.to_f, Digest::MD5.hexdigest(@zones.to_json)]
    Rails.cache.fetch(key, expires_in: 30.days) do
      map = Gtfs::Discord::RideMap.new(segment, zones: @zones).call
      runs = map.line.select { |run| run.size >= 2 }
      next nil if runs.empty? || !TIMETABLE_SOURCES.include?(map.line_source)

      rounded = runs.map { |run| run.map { |lon, lat| [lon.to_f.round(6), lat.to_f.round(6)] } }
      if rounded.size == 1
        { 'type' => 'LineString', 'coordinates' => rounded.first }
      else
        { 'type' => 'MultiLineString', 'coordinates' => rounded }
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[GTFS map] ride #{segment.id} timetable line: #{e.class}: #{e.message}")
    nil
  end

  # GeoJSON lines of the ride points (spec 12.2), oldest first. Points inside
  # a privacy zone are left out of the line as well.
  def ride_point_lines(segment_ids)
    return {} if segment_ids.empty?

    zone_sql = @zones.empty? ? 'FALSE' : TransitSegment.zone_condition(@zones, columns: ['points.lonlat'])
    sql = <<~SQL.squish
      SELECT tsp.transit_segment_id,
             ST_AsGeoJSON(ST_Simplify(ST_MakeLine(points.lonlat::geometry ORDER BY points.timestamp), ?), 6)
      FROM transit_segment_points tsp
      JOIN points ON points.id = tsp.point_id
      WHERE tsp.transit_segment_id IN (?) AND NOT #{zone_sql}
      GROUP BY tsp.transit_segment_id
    SQL
    rows = TransitSegment.connection.select_rows(
      TransitSegment.sanitize_sql_array([sql, SIMPLIFY_DEGREES, segment_ids])
    )
    rows.to_h { |id, json| [id.to_i, JSON.parse(json)] }
  end

  def start_at
    @start_at ||= timestamp_param(:start_at)
  end

  def end_at
    @end_at ||= timestamp_param(:end_at)
  end

  def min_confidence
    value = @params[:min_confidence]
    return nil if value.blank?

    number = Float(value.to_s, exception: false)
    raise InvalidParams, 'min_confidence must be a number between 0 and 1' unless number&.between?(0, 1)

    number
  end

  def status_filter
    value = @params[:status].presence
    return nil unless value

    statuses = value.to_s.split(',') & %w[auto confirmed]
    raise InvalidParams, 'status must be auto and/or confirmed' if statuses.empty?

    statuses
  end

  # Unix seconds or ISO 8601.
  def timestamp_param(key)
    value = @params[key].presence
    return nil unless value
    return value.to_i if value.to_s.match?(/\A\d+\z/)

    Time.iso8601(value.to_s).to_i
  rescue ArgumentError
    raise InvalidParams, "#{key} must be a Unix timestamp or ISO 8601 time"
  end

  def integer_param(key, default, range)
    value = @params[key].presence
    return default unless value

    number = Integer(value.to_s, exception: false)
    raise InvalidParams, "#{key} must be a positive integer" unless number && range.cover?(number)

    number
  end
end
