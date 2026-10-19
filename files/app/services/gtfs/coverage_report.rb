# frozen_string_literal: true

# Tracking coverage for /transit/coverage: per user and local day, the spans
# of time with live points (points closer than MERGE_S join one span), the
# covered minutes, and the longest silent gaps. Reads only (user_id,
# timestamp) of the live points of the period (imports excluded); that is
# the whole cost (no index on import_id), so the page caches the result.
class Gtfs::CoverageReport
  MERGE_S = 15 * 60 # points closer than this belong to one span
  MIN_SPAN_S = 5 * 60 # a lone point still shows as a short span
  GAP_S = 3 * 3600 # a silence of 3 h or more is listed as a gap
  TOP_GAPS = 5

  # days: { Date => { spans: [[from_min, to_min], ...], minutes:, points: } }
  # (minutes of the local day, 0..1440)
  Entry = Struct.new(:user_id, :days, :gaps, :last_ts, keyword_init: true) do
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
    counts = timestamps.map { |ts| @zone.at(ts).to_date }.tally
    Entry.new(user_id:, days: per_day(spans, counts), gaps: gaps.sort_by { |a, b| a - b }.first(TOP_GAPS), last_ts: timestamps.last)
  end

  # Cuts the spans at local midnight into minutes of each day.
  def per_day(spans, counts)
    days = Hash.new { |h, k| h[k] = { spans: [], minutes: 0, points: 0 } }
    spans.each do |from_ts, to_ts|
      to_ts = [to_ts, from_ts + MIN_SPAN_S].max
      cursor = @zone.at(from_ts)
      finish = @zone.at(to_ts)
      while cursor < finish
        day_end = cursor.to_date.next_day.in_time_zone(@zone)
        piece_end = [finish, day_end].min
        start_min = cursor.hour * 60 + cursor.min
        end_min = piece_end == day_end ? 1440 : piece_end.hour * 60 + piece_end.min
        end_min = [end_min, start_min + 1].max
        day = days[cursor.to_date]
        day[:spans] << [start_min, end_min]
        day[:minutes] += end_min - start_min
        cursor = piece_end
      end
    end
    counts.each { |date, n| days[date][:points] = n }
    days.default_proc = nil
    days
  end
end
