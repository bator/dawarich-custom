# frozen_string_literal: true

# Tracking coverage for /transit/coverage: per user and local day, how many
# hours had at least one live point, plus the longest silent gaps. Reads only
# (user_id, timestamp) of the live points of the period (imports excluded);
# that is the whole cost (no index on import_id), so the page caches it.
class Gtfs::CoverageReport
  GAP_S = 3 * 3600 # a silence of 3 h or more is a gap
  TOP_GAPS = 5

  Entry = Struct.new(:user_id, :days, :gaps, :last_ts, keyword_init: true) do
    # days: { Date => [hours_covered, points] }
    def covered_days = days.count { |_, (hours, _)| hours.positive? }
    def mean_hours(total_days) = total_days.zero? ? 0 : days.sum { |_, (hours, _)| hours } / total_days.to_f
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

  # { user_id => Entry }
  def call
    rows = Point.where(user_id: @user_ids, import_id: nil).where('timestamp >= ?', @since.to_i)
                .order(:user_id, :timestamp).pluck(:user_id, :timestamp)
    rows.group_by(&:first).transform_values { |list| build(list.map(&:last)) }
        .each { |user_id, report| report.user_id = user_id }
  end

  private

  def build(timestamps)
    days = Hash.new { |h, k| h[k] = [Set.new, 0] }
    gaps = []
    previous = nil
    timestamps.each do |ts|
      time = @zone.at(ts)
      entry = days[time.to_date]
      entry[0] << time.hour
      entry[1] += 1
      gaps << [previous, ts] if previous && ts - previous >= GAP_S
      previous = ts
    end
    Entry.new(days: days.transform_values { |hours, n| [hours.size, n] },
             gaps: gaps.sort_by { |a, b| a - b }.first(TOP_GAPS), last_ts: previous)
  end
end
