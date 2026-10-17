# frozen_string_literal: true

# Finds the walking legs of a day in the matcher's cleaned points
# (Gtfs::Matching::PointLoader: anomalies, bad accuracy, spikes and privacy
# zones already removed).
#
# - points inside a ride (rides: [[started_at, ended_at], ...]) or inside a
#   vehicle movement window (WindowDetector :moving) are not walking;
# - the rest is split where the GPS stops for MAX_POINT_GAP_SECS or jumps more
#   than MAX_POINT_GAP_M (such a gap is never bridged, not even by Valhalla);
# - a piece is a walking leg when it has MIN_LEG_POINTS, covers
#   MIN_LEG_DISTANCE_M and its 30-second speeds stay at walking pace
#   (p80 <= MAX_WALK_P80_KMH);
# - scope `transit` keeps only legs that end at most ADJACENT_SECS before a
#   ride starts or start at most ADJACENT_SECS after one ends.
class Gtfs::Walk::LegExtractor
  Leg = Struct.new(:points, :adjacent_rides, keyword_init: true) do
    def start_ts = points.first.ts
    def end_ts = points.last.ts

    def distance
      @distance ||= points.each_cons(2).sum { |a, b| Gtfs::Matching::Geo.haversine(a.lon, a.lat, b.lon, b.lat) }
    end
  end

  SPEED_SPAN_SECS = 30

  # rides: [[started_at, ended_at, id], ...] (Gtfs::Walk::Rides; id may be nil)
  def initialize(points, rides:, windows: [], scope: Gtfs::Walk::Config.scope)
    @points = points
    @rides = rides.map { |from, to, id| [from.to_i, to.to_i, id] }
    moving = windows.select { |w| w.kind == :moving }.map { |w| [w.start_ts, w.end_ts] }
    @busy = @rides.map { |from, to, _id| [from, to] } + moving
    @scope = scope.to_s
  end

  def call
    pieces.filter_map do |piece|
      next unless walking?(piece)

      adjacent = adjacent_rides(piece)
      next if @scope != 'all' && adjacent.empty?

      Leg.new(points: piece, adjacent_rides: adjacent)
    end
  end

  # p80 of the speeds over ~30 s spans (km/h); single-fix noise averages out.
  def self.p80_speed_kmh(points)
    speeds = []
    j = 0
    points.each_with_index do |a, i|
      j = i if j < i
      j += 1 while j < points.size - 1 && points[j].ts - a.ts < SPEED_SPAN_SECS
      break if j <= i || points[j].ts - a.ts < SPEED_SPAN_SECS

      dist = (i...j).sum do |k|
        Gtfs::Matching::Geo.haversine(points[k].lon, points[k].lat, points[k + 1].lon, points[k + 1].lat)
      end
      speeds << (dist / (points[j].ts - a.ts) * 3.6)
    end
    return 0.0 if speeds.empty?

    speeds.sort!
    speeds[(speeds.size * 0.8).floor.clamp(0, speeds.size - 1)]
  end

  private

  def pieces
    out = []
    current = []
    @points.each do |p|
      if busy?(p.ts)
        out << current if current.any?
        current = []
        next
      end
      if (prev = current.last) && break_between?(prev, p)
        out << current
        current = []
      end
      current << p
    end
    out << current if current.any?
    out
  end

  def busy?(time)
    @busy.any? { |from, to| time >= from && time <= to }
  end

  def break_between?(prev, nxt)
    c = Gtfs::Walk::Config
    nxt.ts - prev.ts > c::MAX_POINT_GAP_SECS ||
      Gtfs::Matching::Geo.haversine(prev.lon, prev.lat, nxt.lon, nxt.lat) > c::MAX_POINT_GAP_M
  end

  def walking?(piece)
    c = Gtfs::Walk::Config
    return false if piece.size < c::MIN_LEG_POINTS

    leg = Leg.new(points: piece)
    leg.distance >= c::MIN_LEG_DISTANCE_M && self.class.p80_speed_kmh(piece) <= c::MAX_WALK_P80_KMH
  end

  def adjacent_rides(piece)
    limit = Gtfs::Walk::Config::ADJACENT_SECS
    @rides.select do |from, to|
      (from >= piece.last.ts && from - piece.last.ts <= limit) ||
        (piece.first.ts >= to && piece.first.ts - to <= limit)
    end
  end
end
