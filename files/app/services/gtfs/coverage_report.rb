# frozen_string_literal: true

# Tracking coverage for /transit/coverage: per user and local day, the
# covered minutes (points closer than MERGE_S join one span), the hours that
# had a point, the point count, and the longest silent gaps. Reads only (user_id,
# timestamp) of the live points of the period (imports excluded); that is
# the whole cost (no index on import_id), so the page caches the result.
class Gtfs::CoverageReport
  MERGE_S = 15 * 60 # points closer than this belong to one span
  MIN_SPAN_S = 5 * 60 # a lone point still shows as a short span
  GAP_S = 3 * 3600 # a silence of 3 h or more is listed as a gap
  TOP_GAPS = 5

  # days: { Date => { minutes:, points:, hours: [0..23, ...] } } (local days)
  # hour_points: points per local hour of day over the whole period (24 ints)
  Entry = Struct.new(:user_id, :days, :gaps, :last_ts, :hour_points, keyword_init: true) do
    def covered_days = days.count { |_, day| day[:minutes].positive? }
    def covered_minutes = days.sum { |_, day| day[:minutes] }
  end

  attr_reader :from, :to

  def initialize(user_ids, since:, zone:)
    @user_ids = user_ids
    @since = since
    @zone = zone
    @from = zone.at(since.to_i).to_date
    @to = zone.today
  end

  def total_days = (@to - @from).to_i + 1

  # Minutes of the period up to now (today only counts until now).
  def total_minutes
    now = Time.current.in_time_zone(@zone)
    (total_days - 1) * 1440 + now.hour * 60 + now.min
  end

  # "Typical day", per local hour: share = the share of the period's days
  # that had a point in that hour (today's hours count only once they began),
  # mean_points = the average number of points in that hour per such day.
  def rhythm(entry)
    now = Time.current.in_time_zone(@zone)
    counts = Array.new(24, 0)
    entry.days.each_value { |day| day[:hours].each { |h| counts[h] += 1 } }
    (0..23).map do |h|
      possible = total_days - (h > now.hour ? 1 : 0)
      share = possible.positive? ? counts[h].fdiv(possible) : 0.0
      { share:, mean_points: counts[h].positive? ? entry.hour_points[h].fdiv(counts[h]) : 0.0 }
    end
  end

  # { user_id => Entry }
  def call
    rows = Point.where(user_id: @user_ids, import_id: nil).where('timestamp >= ?', @since.to_i)
                .order(:user_id, :timestamp).pluck(:user_id, :timestamp)
    rows.group_by(&:first).to_h { |user_id, list| [user_id, build(user_id, list.map(&:last))] }
  end

  private

  def build(user_id, timestamps)
    spans = []
    gaps = []
    timestamps.each do |ts|
      last = spans.last
      if last && ts - last[1] < MERGE_S
        last[1] = ts
      else
        gaps << [last[1], ts] if last && ts - last[1] >= GAP_S
        spans << [ts, ts]
      end
    end
    counts = Hash.new(0)
    hours = Hash.new { |h, k| h[k] = Set.new }
    hour_points = Array.new(24, 0)
    timestamps.each do |ts|
      time = @zone.at(ts)
      counts[time.to_date] += 1
      hours[time.to_date] << time.hour
      hour_points[time.hour] += 1
    end
    Entry.new(user_id:, days: per_day(spans, counts, hours), hour_points:, gaps: gaps.sort_by { |a, b| a - b }.first(TOP_GAPS), last_ts: timestamps.last)
  end

  # Covered minutes per local day (spans cut at midnight), with the point
  # count and the hours that had a point.
  def per_day(spans, counts, hours)
    minutes = Hash.new(0)
    spans.each do |from_ts, to_ts|
      to_ts = [to_ts, from_ts + MIN_SPAN_S].max
      cursor = @zone.at(from_ts)
      finish = @zone.at(to_ts)
      while cursor < finish
        day_end = cursor.to_date.next_day.in_time_zone(@zone)
        piece_end = [finish, day_end].min
        minutes[cursor.to_date] += ((piece_end - cursor) / 60.0).round
        cursor = piece_end
      end
    end
    counts.keys.to_h do |date|
      [date, { minutes: [minutes[date], 1440].min, points: counts[date], hours: hours[date].to_a.sort }]
    end
  end
end
