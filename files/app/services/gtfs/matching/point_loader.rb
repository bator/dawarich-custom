# frozen_string_literal: true

# Spec 9.1: loads a user's points for a time range (read-only) and cleans
# them for matching. Points are never modified; the cleaned list lives only in
# memory.
#
# - anomaly-flagged points (Dawarich's own filter) are skipped
# - accuracy worse than MAX_ACCURACY_M is dropped (when the field is set)
# - duplicates (same timestamp) keep the most accurate fix
# - single-point spikes faster than MAX_JUMP_SPEED_KMH are dropped
# - points inside the user's privacy zones are dropped (spec 0.1 gate D)
# - `speed` is the reported velocity (m/s) or, if missing, the computed one
class Gtfs::Matching::PointLoader
  MatchPoint = Struct.new(:id, :ts, :lon, :lat, :accuracy, :speed, keyword_init: true)

  # timestamps of the points dropped for low accuracy (see WindowDetector, truncated windows)
  attr_reader :dropped_accuracy_ts

  def initialize(user, from_ts, to_ts, privacy_zones: nil)
    @user = user
    @from_ts = from_ts.to_i
    @to_ts = to_ts.to_i
    @privacy_zones = privacy_zones
    @dropped_accuracy_ts = []
  end

  def call
    points = load_rows
    points = dedupe(points)
    points, inaccurate = points.partition { |p| !(p.accuracy&.positive? && p.accuracy > Gtfs::Config::MAX_ACCURACY_M) }
    points = drop_spikes(points)
    points = drop_privacy_zones(points)
    # points inside privacy zones must not influence anything, not even a flag
    @dropped_accuracy_ts = drop_privacy_zones(inaccurate).map(&:ts)
    fill_speeds(points)
    points
  end

  # True when lon/lat lies inside one of the zones ([{ lon:, lat:, radius: }]).
  def self.in_zones?(lon, lat, zones)
    zones.any? { |z| Gtfs::Matching::Geo.haversine(lon, lat, z[:lon], z[:lat]) <= z[:radius].to_f }
  end

  private

  def load_rows
    rows = Point.where(user_id: @user.id, timestamp: @from_ts...@to_ts).not_anomaly
                .where.not(lonlat: nil).order(:timestamp, :id)
                .pluck(:id, :timestamp, Arel.sql('ST_X(lonlat::geometry)'), Arel.sql('ST_Y(lonlat::geometry)'),
                       :accuracy, :velocity)
    rows.map do |id, ts, lon, lat, accuracy, velocity|
      reported = velocity.to_s.strip
      speed = reported.match?(/\A-?\d+(\.\d+)?\z/) && reported.to_f >= 0 ? reported.to_f : nil
      MatchPoint.new(id:, ts:, lon:, lat:, accuracy:, speed:)
    end
  end

  def dedupe(points)
    points.group_by(&:ts).values.map { |same| same.min_by { |p| p.accuracy || Float::INFINITY } }.sort_by(&:ts)
  end

  def drop_spikes(points)
    max_speed = Gtfs::Config::MAX_JUMP_SPEED_KMH / 3.6
    kept = []
    points.each_with_index do |point, i|
      prev = kept.last
      if prev && speed_between(prev, point) > max_speed
        following = points[i + 1]
        # a lone spike: the next point is consistent with the previous one again
        next if following.nil? || speed_between(prev, following) <= max_speed
      end
      kept << point
    end
    kept
  end

  def drop_privacy_zones(points)
    zones = (@privacy_zones ||= Users::PrivacyZones.new(@user).call)
    return points if zones.empty?

    points.reject { |p| self.class.in_zones?(p.lon, p.lat, zones) }
  end

  def fill_speeds(points)
    points.each_cons(2) do |a, b|
      b.speed ||= speed_between(a, b)
    end
    points.first.speed ||= 0.0 if points.any?
  end

  def speed_between(from, to)
    dt = to.ts - from.ts
    return Float::INFINITY if dt <= 0

    Gtfs::Matching::Geo.haversine(from.lon, from.lat, to.lon, to.lat) / dt
  end
end
