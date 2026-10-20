# frozen_string_literal: true

# Recurring trips for the /transit/stats overview: counted rides grouped by
# direction (boarding stop -> alighting stop), with travel times, lines,
# delays and when they are taken, and paired with the way back (Pair). A trip
# needs MIN_RIDES rides to count as recurring.
class Gtfs::CommuteStats
  MIN_RIDES = 2
  TOP = 12

  Trip = Struct.new(:from, :to, :rides, :zone, keyword_init: true) do
    def count = rides.size
    def durations = rides.map { |s| s.ended_at - s.started_at }.sort
    def median_s = Gtfs::CommuteStats.median(durations)
    def fastest_s = durations.first
    def slowest_s = durations.last
    def last_at = rides.map(&:started_at).max

    # [[sample_segment, count], ...] most used line first
    def lines = Gtfs::CommuteStats.lines(rides)

    def delays = rides.select(&:delay_reliable?).map { |s| s.debug['delay_secs'].to_f }
    def median_delay_s = delays.empty? ? nil : Gtfs::CommuteStats.median(delays.sort)
    def late_share = delays.empty? ? nil : delays.count { |d| d > 300 }.fdiv(delays.size)

    # 24 counts of departures by local hour
    def by_hour
      counts = rides.map { |s| zone.at(s.started_at).hour }.tally
      (0..23).map { |h| counts.fetch(h, 0) }
    end

    # 7 counts, Monday first
    def by_weekday
      counts = rides.map { |s| zone.at(s.started_at).to_date.cwday }.tally
      (1..7).map { |d| counts.fetch(d, 0) }
    end

    # The departure hour with the most rides, with the median duration of
    # the rides in that hour.
    def usual_departure
      hour, n = by_hour.each_with_index.max_by { |count, _| count }&.then { |count, h| [h, count] }
      return nil if n.to_i.zero?

      in_hour = rides.select { |s| zone.at(s.started_at).hour == hour }
      { hour:, count: n, median_s: Gtfs::CommuteStats.median(in_hour.map { |s| s.ended_at - s.started_at }.sort) }
    end
  end

  # A trip and its way back (B -> A), when that is recurring too.
  Pair = Struct.new(:out, :back, keyword_init: true) do
    def trips = [out, back].compact
    def count = trips.sum(&:count)
    def rides = trips.flat_map(&:rides)
    def lines = Gtfs::CommuteStats.lines(rides)
    def by_weekday = trips.map(&:by_weekday).transpose.map(&:sum)
  end

  # [[sample_segment, count], ...] most used first. A line is its mode and
  # name: the same train or route can come from several feeds or route ids
  # (both showed as "IC 849 TÓPART"), and the user knows it by its name.
  def self.lines(rides)
    rides.group_by { |s| [s.mode, s.route_short_name || s.route_long_name] }
         .map { |_, list| [list.first, list.size] }
         .sort_by { |segment, n| [-n, (segment.route_short_name || segment.route_long_name).to_s] }
  end

  def self.median(sorted)
    return nil if sorted.empty?

    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end

  def initialize(rides, zone:)
    @rides = rides
    @zone = zone
  end

  def trips
    @trips ||= @rides.group_by { |s| [s.boarding_stop_name, s.alighting_stop_name] }
                     .reject { |(from, to), _| from.blank? || to.blank? }
                     .map { |(from, to), list| Trip.new(from:, to:, rides: list, zone: @zone) }
                     .select { |trip| trip.count >= MIN_RIDES }
                     .sort_by { |trip| [-trip.count, -trip.last_at] }
                     .first(TOP)
  end

  # Recurring trips with their way back, most rides first.
  def pairs
    @pairs ||= begin
      left = trips.dup
      list = []
      while (trip = left.shift)
        back = left.find { |other| other.from == trip.to && other.to == trip.from }
        left.delete(back)
        list << Pair.new(out: trip, back:)
      end
      list.sort_by { |pair| -pair.count }
    end
  end

  # Share of all counted rides that belong to the shown recurring trips.
  def coverage
    return 0.0 if @rides.empty?

    trips.sum(&:count).fdiv(@rides.size)
  end
end
