# frozen_string_literal: true

# Totals of the rides of a period for /transit/stats, from the already
# loaded rides (the same rows the /transit list shows). Like
# Gtfs::SegmentStats, but for a rolling period instead of a calendar
# month/year, and only counted rides: confirmed and auto-accepted. Uncertain
# rides are only counted as "to review".
class Gtfs::PeriodStats
  TOP = 10

  attr_reader :rides, :to_review

  def initialize(segments, zone:)
    @zone = zone
    @rides, uncertain = segments.partition { |s| !s.uncertain? }
    @to_review = uncertain.size
  end

  def count = rides.size
  def duration_s = rides.sum { |s| duration(s) }
  def distance_m = rides.sum { |s| s.distance_m.to_f }

  # [[mode, { count:, duration_s:, distance_m: }], ...] by count, desc
  def by_mode
    totals(rides.group_by(&:mode))
  end

  # [[feed, { count:, duration_s:, distance_m: }], ...] by count, desc
  def by_feed
    totals(rides.group_by(&:feed))
  end

  # [{ segment:, line:, count:, duration_s: }]: segment is a sample ride of
  # the line, for its mode and route colour.
  def top_lines
    rides.group_by { |s| [s.feed_id, s.route_gtfs_id, s.route_short_name || s.route_long_name] }
         .map { |(_, _, line), list| { segment: list.first, line:, count: list.size, duration_s: list.sum { |s| duration(s) } } }
         .sort_by { |row| [-row[:count], -row[:duration_s], row[:line].to_s] }
         .first(TOP)
  end

  def top_boarding = top(rides.map(&:boarding_stop_name))
  def top_alighting = top(rides.map(&:alighting_stop_name))

  # Ride counts per local week (Monday) or per month, oldest first, with
  # empty buckets filled in: [[Date, count, partial], ...]. The first bucket
  # is partial when the period starts inside it (only rides from `from` are
  # counted), so the view can mark its bar.
  def histogram(from:, by:)
    step = by == :month ? ->(d) { d.next_month } : ->(d) { d + 7 }
    start = bucket(from, by)
    counts = rides.map { |s| bucket(@zone.at(s.started_at).to_date, by) }.tally
    buckets = []
    date = start
    today = @zone.today
    while date <= today
      buckets << [date, counts.fetch(date, 0), date == start && start < from]
      date = step.call(date)
    end
    buckets
  end

  private

  def duration(segment) = segment.ended_at - segment.started_at

  def bucket(date, by) = by == :month ? date.beginning_of_month : date.beginning_of_week

  def totals(groups)
    groups.map { |key, list| [key, { count: list.size, duration_s: list.sum { |s| duration(s) }, distance_m: list.sum { |s| s.distance_m.to_f } }] }
          .sort_by { |_, row| -row[:count] }
  end

  def top(names)
    names.compact.tally.sort_by { |name, count| [-count, name] }.first(TOP)
  end
end
