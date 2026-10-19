# frozen_string_literal: true

# Per-line delays for /transit/punctuality, measured on the user's own rides.
# Only rides whose delay is reliable count (TransitSegment#delay_reliable?:
# no other trip or line fits as well). Delay = scheduled vs observed time of
# the ride, as stored by the matcher in debug['delay_secs'].
class Gtfs::PunctualityStats
  LATE_S = 300 # "late" above 5 min
  EARLY_S = -60 # "early" more than 1 min ahead of the timetable
  MIN_RIDES = 2
  # [key, first hour, last hour + 1] in local time
  DAYPARTS = [[:morning, 6, 9], [:midday, 9, 15], [:afternoon, 15, 19], [:evening, 19, 24], [:night, 0, 6]].freeze

  Line = Struct.new(:segment, :delays, keyword_init: true) do
    def count = delays.size
    def median_s = Gtfs::CommuteStats.median(delays.sort)
    def mean_s = delays.sum / delays.size.to_f
    def p90_s = delays.sort[((delays.size - 1) * 0.9).round]
    def late_share = delays.count { |d| d > Gtfs::PunctualityStats::LATE_S }.fdiv(count)
    def early_share = delays.count { |d| d < Gtfs::PunctualityStats::EARLY_S }.fdiv(count)
  end

  attr_reader :measured

  def initialize(rides, zone:)
    @zone = zone
    @measured = rides.select(&:delay_reliable?)
  end

  def delays = @measured.map { |s| delay(s) }
  def median_s = Gtfs::CommuteStats.median(delays.sort)
  def late_share = @measured.empty? ? nil : delays.count { |d| d > LATE_S }.fdiv(@measured.size)

  # Lines with at least MIN_RIDES measured rides, most ridden first.
  def lines
    @lines ||= @measured.group_by { |s| [s.feed_id, s.route_gtfs_id, s.route_short_name || s.route_long_name] }
                        .map { |_, list| Line.new(segment: list.first, delays: list.map { |s| delay(s) }) }
                        .select { |line| line.count >= MIN_RIDES }
                        .sort_by { |line| [-line.count, line.median_s] }
  end

  # [[daypart, count, median_s], ...] in DAYPARTS order, only non-empty ones
  def by_daypart
    groups = @measured.group_by do |s|
      hour = @zone.at(s.started_at).hour
      DAYPARTS.find { |_, from, to| hour >= from && hour < to }.first
    end
    DAYPARTS.filter_map do |key, _, _|
      list = groups[key]
      next unless list

      [key, list.size, Gtfs::CommuteStats.median(list.map { |s| delay(s) }.sort)]
    end
  end

  private

  def delay(segment) = segment.debug['delay_secs'].to_f
end
