# frozen_string_literal: true

# Builds a user's frequent routes (docs/corridors.md) from the trips of
# Corridors::TripSource and replaces the stored ones:
#   1. cluster: trips whose ends lie within ENDPOINT_M of each other (either
#      direction) and whose shapes are close (mean distance at equal shares of
#      the length < CLUSTER_M) are one route; pointwise identical trips (copied
#      points) count once
#   2. median: start from the longest of the central trips, resampled every
#      BIN m; project every trip onto it, take per bin the median of the trips'
#      lateral offsets, smooth along the line, move the line; repeat
#   3. trips far off the others (a detour) are left out; bins at the ends that
#      fewer than END_SUPPORT of the trips reach are cut; loops the line made
#      (stations, poor signal) are cut out; inner bins with few real fixes are
#      gaps (a tunnel, lost signal), kept for filling later
#   4. the line is smoothed (SMOOTH_M); a route wider than MAX_SPREAD_P90 or
#      still zigzagging (MAX_TURN_PER_KM, e.g. inside a station hall with poor
#      signal) is dropped, and of two routes that mostly overlap
#      (OVERLAP_SHARE within OVERLAP_M) the one with fewer trips
class Corridors::Builder
  G = Corridors::Geometry
  ENDPOINT_M = 200.0
  CLUSTER_M = { 'walking' => 40.0, 'running' => 40.0, 'cycling' => 50.0 }.freeze
  DUPLICATE_M = 0.5
  STEP = 5.0
  BIN = 10.0
  ITERATIONS = 5
  SMOOTH_BINS = 5
  MIN_COVERAGE = 0.6
  END_SUPPORT = 0.5
  GAP_SUPPORT = 0.2
  GAP_MIN_M = 100.0
  MAX_SPREAD_P90 = 15.0
  SMOOTH_M = 30.0 # each side of a point
  MAX_TURN_PER_KM = 1000.0 # degrees of heading change per km of the smoothed line
  OVERLAP_M = 15.0
  OVERLAP_SHARE = 0.7

  Route = Struct.new(:mode, :line, :trips, :track_ids, :spread_p50, :spread_p90, :gaps, keyword_init: true)

  def initialize(user, source: nil)
    @user = user
    @source = source || Corridors::TripSource.new(user)
  end

  # => [Route]; stored unless dry_run
  def call(dry_run: false)
    routes = @source.trips.group_by(&:mode).flat_map do |mode, trips|
      distinct(clusters(trips, mode).filter_map { |members| route(mode, members) })
    end
    store(routes) unless dry_run
    routes
  end

  private

  # => [[Trip oriented like the first one, ...], ...] with at least min_trips each
  def clusters(trips, mode)
    threshold = CLUSTER_M.fetch(mode, 50.0)
    shapes = trips.map { |t| G.fractions(t.xy) }
    ends = trips.map { |t| [t.xy.first, t.xy.last] }
    links = Array.new(trips.size) { {} } # j => reversed?
    trips.each_index do |i|
      (i + 1...trips.size).each do |j|
        reversed = if G.dist(ends[i][0], ends[j][0]) < ENDPOINT_M && G.dist(ends[i][1], ends[j][1]) < ENDPOINT_M then false
                   elsif G.dist(ends[i][0], ends[j][1]) < ENDPOINT_M && G.dist(ends[i][1], ends[j][0]) < ENDPOINT_M then true
                   end
        next if reversed.nil?
        next unless G.mean_distance(shapes[i], reversed ? shapes[j].reverse : shapes[j]) < threshold

        links[i][j] = reversed
        links[j][i] = reversed
      end
    end
    left = Set.new(0...trips.size)
    out = []
    until left.empty?
      head = left.max_by { |i| links[i].keys.count { |j| left.include?(j) } }
      members = [head] + links[head].keys.select { |j| left.include?(j) }
      left.subtract(members)
      oriented = members.map { |j| j == head || !links[head][j] ? trips[j] : reversed_trip(trips[j]) }
      oriented = unique(oriented)
      out << oriented if oriented.size >= Corridors::Config.min_trips
    end
    out
  end

  def reversed_trip(trip) = trip.dup.tap { |t| t.xy = trip.xy.reverse }

  def unique(trips)
    shapes = trips.map { |t| G.fractions(t.xy) }
    kept = []
    trips.each_index { |i| kept << i if kept.none? { |k| G.mean_distance(shapes[i], shapes[k]) < DUPLICATE_M } }
    kept.map { |i| trips[i] }
  end

  def route(mode, trips)
    resampled = trips.map { |t| G.resample(t.xy, STEP) }
    line = G.resample(reference(resampled), BIN)
    kept = Array.new(trips.size, true)
    ITERATIONS.times do
      s = G.lengths(line)
      per_trip = resampled.map { |pts| bin_offsets(line, s, pts) }
      kept = keep(per_trip, line.size)
      shift = line.each_index.map do |b|
        offsets = per_trip.each_index.filter_map { |i| per_trip[i][b] if kept[i] }
        offsets.size >= [3, 0.3 * kept.count(true)].max ? G.median(offsets) : 0.0
      end
      shift = G.moving_median(shift, SMOOTH_BINS)
      normals = G.normals(line)
      line = G.resample(line.each_with_index.map { |p, b| [p[0] + (normals[b][0] * shift[b]), p[1] + (normals[b][1] * shift[b])] }, BIN)
    end
    finish(mode, line, trips, kept)
  end

  # Longest of the trips that are closer than the median to the others: the
  # start must cover the route, a short trip would cut its ends off.
  def reference(resampled)
    shapes = resampled.map { |pts| G.fractions(pts) }
    scores = shapes.map { |a| G.median(shapes.map { |b| G.mean_distance(a, b) }) }
    limit = G.median(scores)
    resampled.each_index.select { |i| scores[i] <= limit }.max_by { |i| G.length(resampled[i]) }.then { |i| resampled[i] }
  end

  # {bin => median signed offset} of one trip
  def bin_offsets(line, s, points)
    G.project(line, s, points).group_by { |station, _| (station / BIN).round.clamp(0, line.size - 1) }
     .transform_values { |pairs| G.median(pairs.map(&:last)) }
  end

  # Trips far off the others (a detour, a wrong cluster member) and trips that
  # cover too little of the line are left out of the median.
  def keep(per_trip, bins)
    scores = per_trip.map { |h| h.empty? ? Float::INFINITY : G.median(h.values.map(&:abs)) }
    finite = scores.reject(&:infinite?)
    med = G.median(finite) || 0.0
    mad = G.median(finite.map { |v| (v - med).abs }) || 0.0
    limit = [med + (4 * 1.4826 * mad), 2 * med, 15.0].max
    per_trip.each_index.map { |i| scores[i] <= limit && per_trip[i].size >= MIN_COVERAGE * bins }
  end

  def finish(mode, line, trips, kept)
    used = trips.each_index.select { |i| kept[i] }
    return nil if used.size < Corridors::Config.min_trips

    s = G.lengths(line)
    support = Array.new(line.size, 0)
    spreads = used.map do |i|
      projected = G.project(line, s, trips[i].xy)
      projected.map { |station, _| (station / BIN).round.clamp(0, line.size - 1) }.uniq.each { |b| support[b] += 1 }
      G.median(projected.map { |_, offset| offset.abs })
    end
    share = support.map { |n| n.to_f / used.size }
    first = share.index { |v| v >= END_SUPPORT }
    last = share.rindex { |v| v >= END_SUPPORT }
    return nil if first.nil? || last - first < 2

    line, share = without_loops(line[first..last], share[first..last])
    line = smooth(line)
    return nil if line.size < 3 || G.percentile(spreads, 0.9).to_f > MAX_SPREAD_P90
    return nil if turn_per_km(line) > MAX_TURN_PER_KM

    Route.new(mode:, line:, trips: used.size, track_ids: used.map { |i| trips[i].track_id },
              spread_p50: G.median(spreads)&.round(1), spread_p90: G.percentile(spreads, 0.9)&.round(1),
              gaps: gaps(share))
  end

  # Moving average over SMOOTH_M on each side; the ends stay.
  def smooth(line)
    w = (SMOOTH_M / BIN).round
    line.each_index.map do |i|
      next line[i] if i.zero? || i == line.size - 1

      part = line[[i - w, 0].max..[i + w, line.size - 1].min]
      [part.sum { |p| p[0] } / part.size, part.sum { |p| p[1] } / part.size]
    end
  end

  def turn_per_km(line)
    turn = line.each_cons(3).sum do |a, b, c|
      d = Math.atan2(c[1] - b[1], c[0] - b[0]) - Math.atan2(b[1] - a[1], b[0] - a[0])
      ((d + Math::PI) % (2 * Math::PI) - Math::PI).abs * 180 / Math::PI
    end
    turn / [G.length(line) / 1000.0, 0.001].max
  end

  # A line crossing itself made a loop (walking around a hall, poor signal):
  # keep the way around it short, from the first segment to the crossing one.
  def without_loops(line, share)
    i = 0
    while i < line.size - 3
      j = (line.size - 2).downto(i + 2).find { |k| crossing(line[i], line[i + 1], line[k], line[k + 1]) }
      if j
        x = crossing(line[i], line[i + 1], line[j], line[j + 1])
        line = line[0..i] + [x] + line[(j + 1)..]
        share = share[0..i] + [share[j]] + share[(j + 1)..]
      end
      i += 1
    end
    [line, share]
  end

  def crossing(a, b, c, d)
    r = [b[0] - a[0], b[1] - a[1]]
    q = [d[0] - c[0], d[1] - c[1]]
    den = (r[0] * q[1]) - (r[1] * q[0])
    return nil if den.abs < 1e-9

    t = (((c[0] - a[0]) * q[1]) - ((c[1] - a[1]) * q[0])) / den
    u = (((c[0] - a[0]) * r[1]) - ((c[1] - a[1]) * r[0])) / den
    [a[0] + (t * r[0]), a[1] + (t * r[1])] if t.between?(0.0, 1.0) && u.between?(0.0, 1.0)
  end

  # Of routes that mostly run on top of each other, the one with more trips.
  def distinct(routes)
    routes.sort_by { |r| -r.trips }.each_with_object([]) do |r, kept|
      kept << r unless kept.any? { |k| overlap(r.line, k.line) >= OVERLAP_SHARE }
    end
  end

  def overlap(line, other)
    s = G.lengths(other)
    G.project(other, s, line, back: Float::INFINITY, forward: Float::INFINITY).count { |_, offset| offset.abs <= OVERLAP_M }.fdiv(line.size)
  end

  # [[from_m, to_m], ...] where under GAP_SUPPORT of the trips have a real fix
  def gaps(share)
    runs = []
    start = nil
    share.each_with_index do |v, i|
      start ||= i if v < GAP_SUPPORT
      next unless start && (v >= GAP_SUPPORT || i == share.size - 1)

      stop = v < GAP_SUPPORT ? i : i - 1
      runs << [(start * BIN).round, (stop * BIN).round] if (stop - start + 1) * BIN >= GAP_MIN_M
      start = nil
    end
    runs
  end

  def store(routes)
    frame = @source.frame
    TrackCorridor.transaction do
      TrackCorridor.where(user_id: @user.id).delete_all
      routes.each do |r|
        coords = r.line.map { |x, y| frame.lonlat(x, y) }
        TrackCorridor.create!(
          user_id: @user.id, mode: r.mode, trips: r.trips, track_ids: r.track_ids,
          path: "SRID=4326;LINESTRING(#{coords.map { |lon, lat| "#{lon.round(7)} #{lat.round(7)}" }.join(', ')})",
          length_m: G.length(r.line).round, spread_p50: r.spread_p50, spread_p90: r.spread_p90, gaps: r.gaps
        )
      end
    end
  end
end
