# frozen_string_literal: true

# Monthly/yearly totals of the visible rides (spec 11 stats endpoint): time
# and distance per vehicle mode, most used lines and stops. Months are the
# user's local months.
class Gtfs::SegmentStats
  TOP = 10

  def initialize(user, year:, month: nil)
    @user = user
    @year = year
    @month = month
  end

  def call
    segments = TransitSegment.visible_for(@user).where(started_at: range).to_a
    {
      year: @year, month: @month,
      count: segments.size,
      duration_s: segments.sum { |s| s.ended_at - s.started_at },
      distance_m: segments.sum { |s| s.distance_m.to_f }.round,
      by_mode: by_mode(segments),
      top_lines: top(segments.map { |s| [s.route_short_name || s.route_long_name, s.mode] })
                 .map { |(line, mode), count| { line:, mode:, count: } },
      top_stops: top(segments.flat_map { |s| [s.boarding_stop_name, s.alighting_stop_name] }.compact)
                 .map { |name, count| { name:, count: } }
    }
  end

  private

  def range
    zone = ActiveSupport::TimeZone[@user.timezone_iana] || Time.zone
    first = zone.local(@year, @month || 1, 1)
    last = @month ? first.next_month : first.next_year
    first.to_i...last.to_i
  end

  def by_mode(segments)
    segments.group_by(&:mode).transform_values do |list|
      { count: list.size, duration_s: list.sum { |s| s.ended_at - s.started_at },
        distance_m: list.sum { |s| s.distance_m.to_f }.round }
    end
  end

  def top(values)
    values.tally.sort_by { |value, count| [-count, value.to_s] }.first(TOP)
  end
end
