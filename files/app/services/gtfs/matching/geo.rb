# frozen_string_literal: true

# Small planar geometry helpers for the matcher. Coordinates are projected to
# a local equirectangular plane (metres) around a reference latitude, which is
# accurate to well under 1% for the distances involved (a city or one train
# ride), and keeps the per-point maths in plain Ruby.
module Gtfs::Matching::Geo
  EARTH_RADIUS_M = 6_371_000.0
  RAD = Math::PI / 180

  module_function

  def haversine(lon1, lat1, lon2, lat2)
    dlat = (lat2 - lat1) * RAD
    dlon = (lon2 - lon1) * RAD
    h = (Math.sin(dlat / 2)**2) + (Math.cos(lat1 * RAD) * Math.cos(lat2 * RAD) * (Math.sin(dlon / 2)**2))
    2 * EARTH_RADIUS_M * Math.asin(Math.sqrt([h, 1.0].min))
  end

  # Local projection: returns a lambda (lon, lat) -> [x, y] in metres.
  def projector(ref_lat)
    kx = EARTH_RADIUS_M * RAD * Math.cos(ref_lat * RAD)
    ky = EARTH_RADIUS_M * RAD
    ->(lon, lat) { [lon * kx, lat * ky] }
  end

  # A polyline in projected coordinates with cumulative distances, able to
  # project points onto itself (optionally restricted to an along-range).
  class Polyline
    attr_reader :xs, :ys, :cumulative, :length

    def initialize(coords, projector)
      @xs = []
      @ys = []
      coords.each do |lon, lat|
        x, y = projector.call(lon, lat)
        next if @xs.any? && @xs.last == x && @ys.last == y

        @xs << x
        @ys << y
      end
      @cumulative = [0.0]
      (1...@xs.size).each do |i|
        @cumulative << (@cumulative.last + Math.hypot(@xs[i] - @xs[i - 1], @ys[i] - @ys[i - 1]))
      end
      @length = @cumulative.last
    end

    def usable?
      @xs.size >= 2 && @length.positive?
    end

    # => [along_m, distance_m] of the closest point of the line, considering
    # only segments that overlap [from, to] (along metres).
    def project(point_x, point_y, from: 0.0, to: Float::INFINITY)
      best_d2 = Float::INFINITY
      best_along = nil
      (0...(@xs.size - 1)).each do |i|
        seg_start = @cumulative[i]
        seg_end = @cumulative[i + 1]
        next if seg_end < from
        break if seg_start > to

        ax = @xs[i]
        ay = @ys[i]
        dx = @xs[i + 1] - ax
        dy = @ys[i + 1] - ay
        len2 = (dx * dx) + (dy * dy)
        t = len2.zero? ? 0.0 : (((point_x - ax) * dx) + ((point_y - ay) * dy)) / len2
        t = t.clamp(0.0, 1.0)
        along = seg_start + (t * (seg_end - seg_start))
        if along < from || along > to
          along = along.clamp(from, to)
          t = seg_end > seg_start ? (along - seg_start) / (seg_end - seg_start) : 0.0
        end
        qx = ax + (t * dx)
        qy = ay + (t * dy)
        d2 = ((point_x - qx)**2) + ((point_y - qy)**2)
        next unless d2 < best_d2

        best_d2 = d2
        best_along = along
      end
      best_along.nil? ? [nil, Float::INFINITY] : [best_along, Math.sqrt(best_d2)]
    end
  end
end
