# frozen_string_literal: true

# Service-day helpers.
#
# 1. `expand` turns calendar.txt + calendar_dates.txt rows into the set of
#    (service_id, date) pairs stored in gtfs_service_days (spec 7.5).
# 2. `active_service_ids` / `service_day_start` answer "what runs on day X"
#    and "when does service day X start" for the matcher (spec 9.3, 17.2).
class Gtfs::ServiceCalendar
  WEEKDAYS = %w[monday tuesday wednesday thursday friday saturday sunday].freeze
  # At most this many days (inclusive) are stored per feed version, counted
  # back from the upper limit; applies to calendar.txt and to calendar_dates.
  MAX_SPAN_DAYS = 5 * 366
  FUTURE_LIMIT_DAYS = 400

  # calendar_rows: [{service_id:, days: [bool x7, monday first], start_date:, end_date:}]
  # date_rows:     [{service_id:, date:, exception_type: 1|2}]
  # window:        optional Range of dates to clamp to (feed_info validity)
  # Returns { service_id => Set<Date> }
  def self.expand(calendar_rows:, date_rows:, window: nil, today: Date.current)
    new(window:, today:).expand(calendar_rows, date_rows)
  end

  def initialize(window: nil, today: Date.current)
    # An inverted feed_info window (start after end) is ignored, otherwise
    # every service would be dropped and the import would fail.
    @window = window if window.nil? || window.begin.nil? || window.end.nil? || window.begin <= window.end
    @today = today
    @upper_limit = [@today + FUTURE_LIMIT_DAYS, @window&.end].compact.min
    @lower_limit = [@upper_limit - MAX_SPAN_DAYS + 1, @window&.begin].compact.max
  end

  def expand(calendar_rows, date_rows)
    services = Hash.new { |h, k| h[k] = Set.new }

    calendar_rows.each do |row|
      range = clamp(row[:start_date], row[:end_date])
      next unless range

      range.each do |date|
        services[row[:service_id]] << date if row[:days][date.cwday - 1]
      end
    end

    date_rows.each do |row|
      case row[:exception_type]
      when 1
        services[row[:service_id]] << row[:date] if in_bounds?(row[:date])
      when 2
        services[row[:service_id]].delete(row[:date]) if services.key?(row[:service_id])
      end
    end

    services.reject { |_, dates| dates.empty? }
  end

  # Start ("00:00") of a GTFS service day: local noon minus 12 hours, so on
  # DST change days the service day is 23 or 25 hours long (spec 17.2).
  def self.service_day_start(date, time_zone)
    zone = time_zone.is_a?(ActiveSupport::TimeZone) ? time_zone : ActiveSupport::TimeZone[time_zone]
    zone.local(date.year, date.month, date.day, 12, 0, 0) - 12.hours
  end

  # service_ids active on `date` for the feed's active version.
  def self.active_service_ids(feed, date, version: feed.active_version)
    Gtfs::ServiceDay.where(feed_id: feed.id, version:, service_date: date).pluck(:service_gtfs_id)
  end

  private

  def clamp(start_date, end_date)
    return nil if start_date.nil? || end_date.nil? || end_date < start_date

    upper = [end_date, @upper_limit].min
    lower = [start_date, @lower_limit].max
    return nil if upper < lower

    lower..upper
  end

  def in_bounds?(date)
    date.between?(@lower_limit, @upper_limit)
  end
end
