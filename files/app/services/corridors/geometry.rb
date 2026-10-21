# frozen_string_literal: true

# Plane geometry for the frequent routes, in local metres (an equirectangular
# frame around the user's data: enough for city- and region-sized routes).
# Polylines are arrays of [x, y].
module Corridors::Geometry
  R = 6_371_000.0

  # lon/lat <-> local metres around (lon0, lat0)
  class Frame
    # centred on the median of [lon, lat] points (e.g. the starts of trips)
    def self.around(points)
      new(Corridors::Geometry.median(points.map(&:first)) || 0.0, Corridors::Geometry.median(points.map(&:last)) || 0.0)
    end

    def initialize(lon0, lat0)
      @lon0 = lon0
      @lat0 = lat0
      @kx = Math.cos(lat0 * Math::PI / 180) * R * Math::PI / 180
      @ky = R * Math::PI / 180
    end

    def xy(lon, lat) = [(lon - @lon0) * @kx, (lat - @lat0) * @ky]
    def lonlat(x, y) = [(x / @kx) + @lon0, (y / @ky) + @lat0]
  end

  module_function

  def dist(a, b) = Math.hypot(a[0] - b[0], a[1] - b[1])

  def lengths(line)
    s = [0.0]
    line.each_cons(2) { |a, b| s << (s.last + dist(a, b)) }
    s
  end

  def length(line) = lengths(line).last

  # Every `step` metres along the line.
  def resample(line, step)
    s = lengths(line)
    total = s.last
    return line.dup if total < step * 2

    out = []
    seg = 0
    t = 0.0
    while t < total
      seg += 1 while seg < s.size - 2 && s[seg + 1] < t
      a = line[seg]
      b = line[seg + 1]
      span = s[seg + 1] - s[seg]
      f = span.positive? ? (t - s[seg]) / span : 0.0
      out << [a[0] + ((b[0] - a[0]) * f), a[1] + ((b[1] - a[1]) * f)]
      t += step
    end
    out << line.last
    out
  end

  # The part of the line between arc lengths `from` and `to` (`s`: its arc
  # lengths), the ends interpolated.
  def slice(line, s, from, to)
    at = lambda do |t|
      i = (bsearch_index(s, t) - 1).clamp(0, line.size - 2)
      span = s[i + 1] - s[i]
      f = span.positive? ? ((t - s[i]) / span).clamp(0.0, 1.0) : 0.0
      [line[i][0] + ((line[i + 1][0] - line[i][0]) * f), line[i][1] + ((line[i + 1][1] - line[i][1]) * f)]
    end
    [at.call(from)] + line.each_index.select { |i| s[i] > from && s[i] < to }.map { |i| line[i] } + [at.call(to)]
  end

  # `k` points at equal shares of the length (for comparing trips' shapes).
  def fractions(line, k = 50)
    s = lengths(line)
    total = s.last
    seg = 0
    Array.new(k) do |i|
      t = total * i / (k - 1)
      seg += 1 while seg < s.size - 2 && s[seg + 1] < t
      a = line[seg]
      b = line[seg + 1] || a
      span = s[seg + 1].to_f - s[seg]
      f = span.positive? ? (t - s[seg]) / span : 0.0
      [a[0] + ((b[0] - a[0]) * f), a[1] + ((b[1] - a[1]) * f)]
    end
  end

  def mean_distance(fa, fb)
    fa.zip(fb).sum { |a, b| dist(a, b) } / fa.size
  end

  # Monotonic projection of `points` onto `line` (arc lengths `s`): for each
  # point [station, signed offset]. The search window moves forward with the
  # trip, so a route that passes near itself does not jump back.
  def project(line, s, points, back: 60.0, forward: 400.0)
    s_prev = 0.0
    points.map do |p|
      lo = [bsearch_index(s, s_prev - back) - 1, 0].max
      hi = [bsearch_index(s, s_prev + forward) + 1, line.size - 1].min
      lo, hi = 0, line.size - 1 if hi <= lo
      best = nil
      (lo...hi).each do |i|
        a = line[i]
        b = line[i + 1]
        vx = b[0] - a[0]
        vy = b[1] - a[1]
        len2 = (vx * vx) + (vy * vy)
        t = len2.positive? ? (((p[0] - a[0]) * vx) + ((p[1] - a[1]) * vy)) / len2 : 0.0
        t = t.clamp(0.0, 1.0)
        dx = p[0] - (a[0] + (vx * t))
        dy = p[1] - (a[1] + (vy * t))
        d2 = (dx * dx) + (dy * dy)
        next if best && d2 >= best[0]

        cross = (vx * (p[1] - a[1])) - (vy * (p[0] - a[0]))
        best = [d2, s[i] + (t * Math.sqrt(len2)), cross.negative? ? -Math.sqrt(d2) : Math.sqrt(d2)]
      end
      s_prev = [s_prev, best[1]].max
      [best[1], best[2]]
    end
  end

  # first index with s[i] >= value
  def bsearch_index(s, value)
    s.bsearch_index { |x| x >= value } || s.size
  end

  def normals(line)
    line.each_index.map do |i|
      a = line[[i - 1, 0].max]
      b = line[[i + 1, line.size - 1].min]
      dx = b[0] - a[0]
      dy = b[1] - a[1]
      n = Math.hypot(dx, dy)
      n.positive? ? [-dy / n, dx / n] : [0.0, 0.0]
    end
  end

  def median(values)
    sorted = values.compact.sort
    return nil if sorted.empty?

    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end

  def percentile(values, share)
    sorted = values.compact.sort
    return nil if sorted.empty?

    sorted[((sorted.size - 1) * share).round]
  end

  def moving_median(values, window)
    half = window / 2
    values.each_index.map do |i|
      median(values[[i - half, 0].max..[i + half, values.size - 1].min]) || 0.0
    end
  end
end
