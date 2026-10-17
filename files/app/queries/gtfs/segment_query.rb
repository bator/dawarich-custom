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

  attr_reader :user

  def initialize(user, params = {})
    @user = user
    @params = params.to_h.with_indifferent_access
    @zones = Users::PrivacyZones.new(user).call
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

  # GeoJSON lines of the ride points (spec 12.2), oldest first. Points inside
  # a privacy zone are left out of the line as well.
  def geometries(segment_ids)
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

  private

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
