# frozen_string_literal: true

# Delays for /transit/punctuality, measured on the user's own rides. Only
# rides whose delay is reliable count (TransitSegment#delay_reliable?: no
# other trip or line fits as well). Delay = observed vs timetable time of the
# ride, as stored by the matcher in debug['delay_secs'].
#
# Like railway punctuality figures (e.g. Deutsche Bahn), the headline is the
# share of rides within a tolerance, not an average: on time within 1 min and
# within 5 min. Every ride also falls into one category:
#   early   more than 1 min ahead of the timetable
#   on_time within ±1 min
#   slight  1–5 min late
#   late    more than 5 min late
class Gtfs::PunctualityStats
  ON_TIME_S = 60
  LATE_S = 300
  CATEGORIES = %i[early on_time slight late].freeze
  MIN_RIDES = 2
  # Histogram: one bin per minute from HIST_FROM to HIST_TO, the ends collect the tails.
  HIST_FROM = -3
  HIST_TO = 15

  def self.category(delay)
    if delay < -ON_TIME_S then :early
    elsif delay <= ON_TIME_S then :on_time
    elsif delay <= LATE_S then :slight
    else :late
    end
  end

  # { early:, on_time:, slight:, late: } shares (0..1)
  def self.shares(delays)
    return CATEGORIES.to_h { |c| [c, 0.0] } if delays.empty?

    counts = delays.map { |d| category(d) }.tally
    CATEGORIES.to_h { |c| [c, counts.fetch(c, 0).fdiv(delays.size)] }
  end

  Line = Struct.new(:segment, :delays, keyword_init: true) do
    def count = delays.size
    def median_s = Gtfs::CommuteStats.median(delays.sort)
    def shares = Gtfs::PunctualityStats.shares(delays)
    def within_5 = delays.count { |d| d <= Gtfs::PunctualityStats::LATE_S }.fdiv(count)
  end

  attr_reader :measured

  def initialize(rides, zone:)
    @zone = zone
    @measured = rides.select(&:delay_reliable?)
  end

  def delays = @measured.map { |s| delay(s) }
  def median_s = Gtfs::CommuteStats.median(delays.sort)
  def shares = self.class.shares(delays)
  def within_1 = ratio { |d| d.abs <= ON_TIME_S }
  def within_5 = ratio { |d| d <= LATE_S }

  # [[minute, count, category], ...] from HIST_FROM to HIST_TO; the first
  # bin holds everything earlier, the last everything later.
  def histogram
    counts = delays.map { |d| (d / 60.0).round.clamp(HIST_FROM, HIST_TO) }.tally
    (HIST_FROM..HIST_TO).map { |m| [m, counts.fetch(m, 0), self.class.category(m * 60)] }
  end

  # Lines with at least MIN_RIDES measured rides, most ridden first.
  def lines
    @lines ||= @measured.group_by { |s| [s.feed_id, s.route_gtfs_id, s.route_short_name || s.route_long_name] }
                        .map { |_, list| Line.new(segment: list.first, delays: list.map { |s| delay(s) }) }
                        .select { |line| line.count >= MIN_RIDES }
                        .sort_by { |line| [-line.count, -line.within_5] }
  end

  private

  def ratio(&)
    list = delays
    list.empty? ? nil : list.count(&).fdiv(list.size)
  end

  def delay(segment) = segment.debug['delay_secs'].to_f
end
