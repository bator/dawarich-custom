# frozen_string_literal: true

# Spec 9.2: finds the time windows that look like riding a vehicle.
#
# The detector works on the cleaned points directly. (Spec 2.0 suggests
# reusing Dawarich's track segmentation; on real data its segments are
# mostly unclassified and are rewritten by other tools, so the matcher keeps
# its own heuristic and does not depend on tracks being calculated.)
#
# 1. A point is "moving" when its speed, smoothed over +/-SPEED_SMOOTHING_SECS,
#    is at least MOVING_SPEED_KMH.
# 2. Moving runs are joined across short pauses (stops, traffic lights): at
#    most PAUSE_MAX_SECS and PAUSE_MAX_DISTANCE metres. A longer or walking
#    pause separates two rides. The pauses inside a window are remembered so
#    the matcher can retry the halves (a short transfer inside one window).
# 3. Consecutive points more than GAP_SECS apart split the stream; such a gap
#    becomes a separate :gap window (spec 9.6, underground) when it spans at
#    least MIN_SEGMENT_DISTANCE. A shorter outage (from GAP_MODE_MIN_SECS) is
#    a :gap window too when it is also faster than MIN_VEHICLE_SPEED_KMH and
#    not inside a moving window (a few metro stations).
# 4. A window is kept when it lasts MIN_SEGMENT_DURATION, covers
#    MIN_SEGMENT_DISTANCE and is faster than MIN_VEHICLE_SPEED_KMH on average.
#    Slower windows are kept as :slow; the matcher only uses them when both
#    ends are near stops and part of the window is faster than walking.
# 5. Sparse mode, decided locally: a gap longer than GAP_SECS splits the
#    stream only when it is also longer than SPARSE_GAP_SECS or the median
#    of the SPARSE_SPACING_NEIGHBOURS steps on each side is at most
#    SPARSE_MEDIAN_SPACING_SECS, so a ride sampled every few minutes is not
#    cut into gap windows while a dense day keeps its gap windows. Each
#    window carries `sparse` (median spacing of its own points), which the
#    scorer uses, so both take the same per-ride decision.
#
# Each window remembers `moving_start` (index of its first moving point:
# for rail the boarding time is taken there, not at a stationary fix or a
# gap edge before it) and `truncated` (a point dropped for low accuracy lies
# within TRUNCATION_SECS before its start or after its end). `board_from_gap`
# is set by the matcher on a gap + movement pair whose start is a gap edge.
class Gtfs::Matching::WindowDetector
  # truncated_start / truncated_end: which side the dropped point is on
  # (truncated = either). A window built without them counts as truncated
  # at the end when `truncated` is set (the conservative side).
  Window = Struct.new(:points, :kind, :pauses, :moving_start, :board_from_gap, :truncated, :sparse,
                      :truncated_start, :truncated_end, keyword_init: true) do
    def start_ts = points.first.ts
    def end_ts = points.last.ts
    def duration = end_ts - start_ts

    def distance
      @distance ||= points.each_cons(2).sum { |a, b| Gtfs::Matching::Geo.haversine(a.lon, a.lat, b.lon, b.lat) }
    end

    def avg_speed_kmh
      duration.positive? ? distance / duration * 3.6 : 0.0
    end

    # 80th percentile of the pairwise speeds (km/h), robust against one fast GPS jump
    def p80_speed_kmh
      speeds = points.each_cons(2).filter_map do |a, b|
        dt = b.ts - a.ts
        Gtfs::Matching::Geo.haversine(a.lon, a.lat, b.lon, b.lat) / dt * 3.6 if dt.positive?
      end.sort
      speeds.empty? ? 0.0 : speeds[(speeds.size * 0.8).floor.clamp(0, speeds.size - 1)]
    end

    def max_gap_secs
      points.each_cons(2).map { |a, b| b.ts - a.ts }.max || 0
    end

    def gap? = kind == :gap
    def slow? = kind == :slow

    # Median spacing of the points above SPARSE_MEDIAN_SPACING_SECS
    def self.sparse_points?(points)
      spacings = points.each_cons(2).map { |a, b| b.ts - a.ts }.sort
      spacings.any? && spacings[spacings.size / 2] > Gtfs::Config::SPARSE_MEDIAN_SPACING_SECS
    end

    # Splits at the longest remembered pause -> [left, right] (each with its own pauses).
    # A pause ends at the first point of a moving run, so the right half
    # starts moving at 0; the left half keeps moving_start only if it is in it.
    def split
      return [] if pauses.blank?

      cut = pauses.max_by { |(from, to)| points[to].ts - points[from].ts }
      from, to = cut
      left = points[0..from]
      right = points[to..]
      [
        Window.new(points: left, kind:, pauses: pauses.select { |p| p[1] <= from },
                   moving_start: moving_start && moving_start <= from ? moving_start : nil, truncated:,
                   truncated_start:, truncated_end:,
                   sparse: Window.sparse_points?(left)),
        Window.new(points: right, kind:, pauses: pauses.select { |p| p[0] >= to }.map { |a, b| [a - to, b - to] },
                   moving_start: moving_start && moving_start > to ? moving_start - to : 0, truncated:,
                   truncated_start:, truncated_end:,
                   sparse: Window.sparse_points?(right))
      ]
    end
  end

  def initialize(points, dropped_ts: [])
    @points = points
    @dropped_ts = dropped_ts.sort
  end

  def call
    windows = []
    chunks.each_with_index do |chunk, index|
      windows.concat(moving_windows(chunk))
      following = chunks[index + 1]
      windows << gap_window(chunk.last, following.first) if following && gap_candidate?(chunk.last, following.first)
    end
    windows.concat(short_gap_windows(windows))
    windows = self.class.join_sparse(windows.compact.sort_by(&:start_ts))
    windows.each do |w|
      w.truncated_start = truncated_start?(w)
      w.truncated_end = truncated_end?(w)
      w.truncated = w.truncated_start || w.truncated_end
      # a joined window stays sparse (review K3): it must not auto-accept
      w.sparse = w.sparse || Window.sparse_points?(w.points) unless w.gap?
    end
    windows
  end

  # Review 10-16 a: on a sparse track one ride can come out as two moving
  # windows a few seconds apart (user 1, 10-15: 16:21:58-16:37:25 with 3
  # points and 16:37:43-17:15:04); neither half fits the train from its real
  # boarding stop. Neighbouring non-gap windows are joined when at least one
  # is sparse and they are at most SPARSE_JOIN_GAP_SECS apart. The seam is
  # kept as a pause, so the matcher can still retry the halves (transfer).
  def self.join_sparse(windows)
    windows.each_with_object([]) do |window, out|
      previous = out.last
      if previous && joinable?(previous, window)
        out[-1] = join(previous, window)
      else
        out << window
      end
    end
  end

  # Never a :slow (walking) window, and the result is always sparse (review
  # K3), so it is capped uncertain and the matcher tries the halves too.
  def self.joinable?(first, second)
    first.kind == :moving && second.kind == :moving &&
      (second.start_ts - first.end_ts).between?(0, Gtfs::Config::SPARSE_JOIN_GAP_SECS) &&
      (Window.sparse_points?(first.points) || Window.sparse_points?(second.points))
  end

  def self.join(first, second)
    points = (first.points + second.points).uniq(&:ts)
    offset = points.index { |p| p.ts == second.start_ts }
    seam = [[offset - 1, offset]]
    pauses = first.pauses + seam + second.pauses.map { |a, b| [a + offset, b + offset] }
    joined = Window.new(points:, kind: :moving, pauses:, moving_start: first.moving_start || 0, sparse: true)
    joined.kind = :slow if joined.avg_speed_kmh < Gtfs::Config::MIN_VEHICLE_SPEED_KMH
    joined
  end

  def self.long_enough?(window)
    window.duration >= Gtfs::Config::MIN_SEGMENT_DURATION && window.distance >= Gtfs::Config::MIN_SEGMENT_DISTANCE
  end

  private

  # Splits the point stream at GPS gaps longer than GAP_SECS (in a locally
  # sparse stretch: longer than SPARSE_GAP_SECS).
  def chunks
    @chunks ||= begin
      index = -1
      @points.slice_when do |a, b|
        index += 1
        dt = b.ts - a.ts
        dt > Gtfs::Config::GAP_SECS && (dt > Gtfs::Config::SPARSE_GAP_SECS || !sparse_around?(index))
      end.to_a
    end
  end

  # Median of the steps around step `index` (the gap itself excluded)
  def sparse_around?(index)
    n = Gtfs::Config::SPARSE_SPACING_NEIGHBOURS
    steps = spacings
    around = steps[[index - n, 0].max...index] + (steps[(index + 1)..(index + n)] || [])
    return false if around.empty?

    around.sort[around.size / 2] > Gtfs::Config::SPARSE_MEDIAN_SPACING_SECS
  end

  def spacings
    @spacings ||= @points.each_cons(2).map { |a, b| b.ts - a.ts }
  end

  def truncated_start?(window)
    limit = Gtfs::Config::TRUNCATION_SECS
    @dropped_ts.any? { |ts| ts.between?(window.start_ts - limit, window.start_ts) }
  end

  def truncated_end?(window)
    limit = Gtfs::Config::TRUNCATION_SECS
    @dropped_ts.any? { |ts| ts.between?(window.end_ts, window.end_ts + limit) }
  end

  def moving_windows(chunk)
    return [] if chunk.size < 2

    moving = smoothed_moving_flags(chunk)
    runs = moving_runs(moving)
    merged = merge_runs(chunk, runs)
    merged.filter_map do |first, last, pauses|
      # include the stationary fix just before boarding / after alighting
      from = [first - 1, 0].max
      to = [last + 1, chunk.size - 1].min
      shifted = pauses.map { |a, b| [a - from, b - from] }
      window = Window.new(points: chunk[from..to], kind: :moving, pauses: shifted, moving_start: first - from)
      next unless self.class.long_enough?(window)

      window.kind = :slow if window.avg_speed_kmh < Gtfs::Config::MIN_VEHICLE_SPEED_KMH
      window
    end
  end

  def smoothed_moving_flags(chunk)
    half = Gtfs::Config::SPEED_SMOOTHING_SECS
    threshold = Gtfs::Config::MOVING_SPEED_KMH / 3.6
    lo = 0
    hi = 0
    chunk.each_with_index.map do |point, i|
      lo += 1 while chunk[lo].ts < point.ts - half
      hi = i if hi < i
      hi += 1 while hi + 1 < chunk.size && chunk[hi + 1].ts <= point.ts + half
      a = chunk[lo]
      b = chunk[hi]
      if lo == hi
        a = chunk[[i - 1, 0].max]
        b = chunk[[i + 1, chunk.size - 1].min]
      end
      dt = b.ts - a.ts
      dt.positive? && Gtfs::Matching::Geo.haversine(a.lon, a.lat, b.lon, b.lat) / dt >= threshold
    end
  end

  # => [[first_index, last_index], ...] of consecutive moving points
  def moving_runs(flags)
    runs = []
    start = nil
    flags.each_with_index do |moving, i|
      start = i if moving && start.nil?
      next if moving || start.nil?

      runs << [start, i - 1]
      start = nil
    end
    runs << [start, flags.size - 1] if start
    runs
  end

  # Joins runs separated by a short, nearly stationary pause.
  # => [[first, last, pauses], ...] with pauses as [[from_index, to_index], ...]
  def merge_runs(chunk, runs)
    merged = []
    runs.each do |first, last|
      previous = merged.last
      if previous && pause?(chunk, previous[1], first)
        previous[2] << [previous[1], first]
        previous[1] = last
      else
        merged << [first, last, []]
      end
    end
    merged
  end

  def pause?(chunk, from, to)
    a = chunk[from]
    b = chunk[to]
    b.ts - a.ts <= Gtfs::Config::PAUSE_MAX_SECS &&
      Gtfs::Matching::Geo.haversine(a.lon, a.lat, b.lon, b.lat) <= Gtfs::Config::PAUSE_MAX_DISTANCE
  end

  def gap_candidate?(before, after)
    dt = after.ts - before.ts
    dt <= Gtfs::Config::MAX_GAP_SECS &&
      Gtfs::Matching::Geo.haversine(before.lon, before.lat, after.lon, after.lat) >= Gtfs::Config::MIN_SEGMENT_DISTANCE
  end

  # 9.6: an outage shorter than GAP_SECS (a few metro stations) between two
  # points far enough apart to need a vehicle, unless a moving window already
  # contains it.
  def short_gap_windows(existing)
    chunks.flat_map do |chunk|
      chunk.each_cons(2).filter_map do |a, b|
        dt = b.ts - a.ts
        next if dt < Gtfs::Config::GAP_MODE_MIN_SECS || !gap_candidate?(a, b)

        kmh = Gtfs::Matching::Geo.haversine(a.lon, a.lat, b.lon, b.lat) / dt * 3.6
        next if kmh < Gtfs::Config::MIN_VEHICLE_SPEED_KMH
        next if existing.any? { |w| !w.gap? && w.start_ts <= a.ts && w.end_ts >= b.ts }

        gap_window(a, b)
      end
    end
  end

  def gap_window(before, after)
    Window.new(points: [before, after], kind: :gap, pauses: [])
  end
end
