# frozen_string_literal: true

# Builds a user's frequent routes (docs/corridors.md) from the trips of
# Corridors::TripSource and replaces the stored ones:
#   1. cluster: trips whose ends lie within ENDPOINT_M of each other (either
#      direction) and whose shapes are close (mean distance at equal shares of
#      the length < CLUSTER_M) are one route; pointwise identical trips (copied
#      points) count once
#   2. median: every trip is smoothed along its length (TRIP_SMOOTH_M, GPS
#      zigzag would make lengths and samples depend on chance); the guide is the
#      median of the trips' points at equal shares of their lengths, smoothed;
#      every trip is projected onto it, the line moves to the median of their
#      sideways offsets (interpolated at each point of the line), REFINE times
#   3. trips far off the line (a detour) are left out and the median is built
#      again without them; the ends are where END_SUPPORT of the trips have
#      started and still go; loops the line made (stations, poor signal) are
#      cut out; inner bins with few real fixes are gaps (a tunnel, lost signal)
#   4. the line is smoothed (SMOOTH_M); a route wider than MAX_SPREAD_P90 or
#      still zigzagging (MAX_TURN_PER_KM, e.g. inside a station hall with poor
#      signal) is dropped, and of two routes that mostly overlap
#      (OVERLAP_SHARE within OVERLAP_M) the one with fewer trips
#   5. the gaps of walking and running routes are routed through
#      (Corridors::GapFiller), else they stay the median
# No step hangs on one chosen trip or on where its samples fall, and the
# decisions left (trips left out, the checks of 4.) are made on measures that
# move smoothly with the fixes: the same trips give the same routes, whatever
# the frame of the local metres.
class Corridors::Builder
  G = Corridors::Geometry
  ENDPOINT_M = 200.0
  CLUSTER_M = { 'walking' => 40.0, 'running' => 40.0, 'cycling' => 50.0 }.freeze
  DUPLICATE_M = 0.5
  STEP = 5.0
  BIN = 10.0
  TRIP_SMOOTH_M = 20.0 # each side of a fix, before resampling (GPS zigzag)
  GUIDE_SMOOTH_M = 50.0
  HEADING_M = 30.0 # the guide's ends run on in the direction of their last HEADING_M
  REFINE = 2
  SHIFT_BINS = 2 # moves averaged over this many bins on each side
  MIN_COVERAGE = 0.6
  NEAR_M = 10.0
  FAR_M = 30.0
  MAX_OFF_SHARE = 0.3
  END_SUPPORT = 0.5
  GAP_SUPPORT = 0.2
  GAP_MIN_M = 100.0
  MAX_SPREAD_P90 = 15.0
  SMOOTH_M = 30.0 # each side of a point
  MAX_TURN_PER_KM = 1000.0 # degrees of heading change per km of the smoothed line
  OVERLAP_M = 25.0
  OVERLAP_SHARE = 0.7

  # line in local metres of `frame` (centred on the route's trips, so distances
  # hold wherever the source's frame is); gaps / filled: [[from_m, to_m], ...]
  # along the line (filled: routed through a gap)
  Route = Struct.new(:mode, :frame, :line, :trips, :track_ids, :spread_p50, :spread_p90, :gaps, :filled,
                     keyword_init: true)

  def initialize(user, source: nil)
    @user = user
    @source = source || Corridors::TripSource.new(user)
  end

  # => [Route]; stored unless dry_run. A dry run does not route the gaps either
  # (no request to the Atlas) unless fill: true.
  def call(dry_run: false, fill: !dry_run)
    routes = @source.trips.group_by(&:mode).flat_map do |mode, trips|
      distinct(clusters(trips, mode).filter_map do |members|
        frame = G::Frame.around(members.map { |t| t.lonlat.first })
        route(mode, members.map { |t| t.in_frame(frame) }, frame)
      end)
    end
    routes.each { |r| fill ? fill(r) : unfilled(r) }
    store(routes) unless dry_run
    routes
  end

  private

  # => [[Trip oriented like the first one, ...], ...] with at least min_trips each
  def clusters(trips, mode)
    threshold = CLUSTER_M.fetch(mode, 50.0)
    shapes = trips.map { |t| G.shape(t.lonlat) }
    ends = trips.map { |t| [t.lonlat.first, t.lonlat.last] }
    links = Array.new(trips.size) { {} } # j => reversed?
    trips.each_index do |i|
      (i + 1...trips.size).each do |j|
        reversed = if G.metres(ends[i][0], ends[j][0]) < ENDPOINT_M && G.metres(ends[i][1], ends[j][1]) < ENDPOINT_M then false
                   elsif G.metres(ends[i][0], ends[j][1]) < ENDPOINT_M && G.metres(ends[i][1], ends[j][0]) < ENDPOINT_M then true
                   end
        next if reversed.nil?
        next unless G.mean_metres(shapes[i], reversed ? shapes[j].reverse : shapes[j]) < threshold

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
      oriented = members.map { |j| j == head || !links[head][j] ? trips[j] : trips[j].reversed }
      oriented = unique(oriented)
      out << oriented if oriented.size >= Corridors::Config.min_trips
    end
    out
  end

  def unique(trips)
    shapes = trips.map { |t| G.shape(t.lonlat) }
    kept = []
    trips.each_index { |i| kept << i if kept.none? { |k| G.mean_metres(shapes[i], shapes[k]) < DUPLICATE_M } }
    kept.map { |i| trips[i] }
  end

  def route(mode, trips, frame)
    smoothed = trips.map { |t| G.resample(G.smooth_track(t.xy, TRIP_SMOOTH_M), STEP) }
    line = median(guide(smoothed), smoothed)
    s = G.lengths(line)
    kept = keep(smoothed.map { |pts| offsets(line, s, pts) })
    return nil if kept.count(true) < Corridors::Config.min_trips

    unless kept.all?
      used = smoothed.select.with_index { |_, i| kept[i] }
      line = median(guide(used), used)
    end
    finish(mode, frame, line, trips, kept)
  end

  # A first course of the route that no single trip decides: the median of
  # the trips' points at equal shares of their lengths, smoothed, and run on
  # straight for ENDPOINT_M at both ends: it starts where the median trip
  # starts, while the line may have to start before that (where half of the
  # trips have started); the median moves the extension onto the trips that
  # go there, and #finish cuts it.
  def guide(trips)
    k = [(G.median(trips.map { |t| G.length(t) }) / STEP).round, 2].max
    shares = trips.map { |t| G.fractions(t, k) }
    points = Array.new(k) { |j| [G.median(shares.map { |f| f[j][0] }), G.median(shares.map { |f| f[j][1] })] }
    line = G.resample(G.smooth_track(points, GUIDE_SMOOTH_M), BIN)
    extended(extended(line, ENDPOINT_M).reverse, ENDPOINT_M).reverse
  end

  # The line run on straight before its start (in the direction of its first
  # HEADING_M) by `metres`.
  def extended(line, metres)
    s = G.lengths(line)
    return line if line.size < 2 || s.last <= 0

    a = line.first
    b = G.slice(line, s, 0.0, [HEADING_M, s.last].min).last
    d = G.dist(a, b)
    return line if d <= 0

    ux = (a[0] - b[0]) / d
    uy = (a[1] - b[1]) / d
    (metres / BIN).round.downto(1).map { |n| [a[0] + (ux * n * BIN), a[1] + (uy * n * BIN)] } + line
  end

  # Moves the line to the median of the trips' sideways offsets (where enough
  # of them pass), averaged along the line; REFINE times.
  def median(line, smoothed)
    REFINE.times do
      s = G.lengths(line)
      per_trip = smoothed.map { |pts| offsets(line, s, pts) }
      shift = line.each_index.map do |b|
        values = per_trip.filter_map { |h| h[b] }
        values.size >= [3, 0.3 * smoothed.size].max ? G.median(values) : 0.0
      end
      shift = G.moving_average(shift, SHIFT_BINS)
      normals = G.normals(line)
      line = G.resample(line.each_with_index.map { |p, b| [p[0] + (normals[b][0] * shift[b]), p[1] + (normals[b][1] * shift[b])] }, BIN)
    end
    line
  end

  # {point of the line => signed offset} of one trip at the points it passes,
  # interpolated between its own points (not rounded to the nearest point:
  # that would make the median jump); points beyond the ends of the line have
  # no sideways offset and are left out
  def offsets(line, s, points)
    out = {}
    inside(line, s, points).each_cons(2) do |(s0, o0), (s1, o1)|
      next unless s1 > s0

      b = G.bsearch_index(s, s0)
      while b < s.size && s[b] <= s1
        out[b] ||= o0 + ((o1 - o0) * (s[b] - s0) / (s1 - s0))
        b += 1
      end
    end
    out
  end

  # [station, signed offset] of the points that lie along the line, not beyond its ends
  def inside(line, s, points) = G.project(line, s, points).select { |station, _| station.positive? && station < s.last - 1e-6 }

  # Trips that run off the line for much of their way (a detour, a wrong
  # cluster member: more than MAX_OFF_SHARE and more than the others do) and
  # trips that cover too little of the core (the part most trips pass; not of
  # the line, which may run on with a long start) are left out of the median.
  # Off is measured smoothly (NEAR_M on it, FAR_M off it, linear in between):
  # a hard limit, or the median distance of a trip that is half on and half
  # off, would flip with the slightest change of the line.
  def keep(per_trip)
    reach = Hash.new(0)
    per_trip.each { |h| h.each_key { |b| reach[b] += 1 } }
    core = reach.select { |_, n| n >= END_SUPPORT * per_trip.size }.keys
    scores = per_trip.map do |h|
      h.empty? ? 1.0 : h.values.sum { |v| ((v.abs - NEAR_M) / (FAR_M - NEAR_M)).clamp(0.0, 1.0) } / h.size
    end
    med = G.median(scores)
    mad = G.median(scores.map { |v| (v - med).abs })
    limit = [med + (4 * 1.4826 * mad), MAX_OFF_SHARE].max
    per_trip.each_index.map { |i| scores[i] <= limit && (per_trip[i].keys & core).size >= MIN_COVERAGE * core.size }
  end

  # The line runs from where END_SUPPORT of the kept trips have started to
  # where as many still go (along the line, so it moves smoothly with them;
  # the same count of trips at both ends, also for an even number of them).
  def finish(mode, frame, line, trips, kept)
    used = trips.each_index.select { |i| kept[i] }
    return nil if used.size < Corridors::Config.min_trips

    s = G.lengths(line)
    projected = used.map { |i| G.project(line, s, trips[i].xy) }
    reached = (used.size * END_SUPPORT).ceil
    from = projected.map { |pairs| pairs.map(&:first).min }.sort[reached - 1]
    to = projected.map { |pairs| pairs.map(&:first).max }.sort.reverse[reached - 1]
    return nil if to - from < 3 * BIN

    line = G.resample(G.slice(line, s, from, to), BIN)
    s = G.lengths(line)
    support = Array.new(line.size, 0)
    spreads = used.map do |i|
      along = inside(line, s, trips[i].xy)
      along.map { |station, _| (station / BIN).round.clamp(0, line.size - 1) }.uniq.each { |b| support[b] += 1 }
      G.median(along.map { |_, offset| offset.abs })
    end
    share = support.map { |n| n.to_f / used.size }
    line, share = without_loops(line, share)
    line = smooth(line)
    return nil if line.size < 3 || G.percentile(spreads, 0.9).to_f > MAX_SPREAD_P90
    return nil if turn_per_km(line) > MAX_TURN_PER_KM

    Route.new(mode:, frame:, line:, trips: used.size, track_ids: used.map { |i| trips[i].track_id },
              spread_p50: G.median(spreads)&.round(1), spread_p90: G.percentile(spreads, 0.9)&.round(1),
              gaps: gaps(share))
  end

  # gaps of bins => routed or kept, both in metres along the final line
  def fill(route)
    result = gap_filler.call(route.mode, route.line, route.gaps, frame: route.frame)
    route.line = result.line
    route.gaps = result.gaps
    route.filled = result.filled
  end

  # gaps of bins => metres, nothing routed (dry run)
  def unfilled(route)
    s = G.lengths(route.line)
    route.gaps = route.gaps.map { |first, last| [s[first].round, s[last].round] }
    route.filled = []
  end

  def gap_filler = @gap_filler ||= Corridors::GapFiller.new(@user)

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

  # Of routes that mostly run on top of each other, the one with more trips
  # (compared in the frame of the one kept: each route has its own). OVERLAP_M
  # is wide enough for the two directions of one way (other pavement, other
  # platform), which the clustering may part.
  def distinct(routes)
    routes.sort_by { |r| [-r.trips, -G.length(r.line), r.track_ids.min] }.each_with_object([]) do |r, kept|
      kept << r unless kept.any? { |k| overlap(in_frame(r, k.frame), k.line) >= OVERLAP_SHARE }
    end
  end

  def in_frame(route, frame) = route.line.map { |x, y| frame.xy(*route.frame.lonlat(x, y)) }

  def overlap(line, other)
    s = G.lengths(other)
    G.project(other, s, line, back: Float::INFINITY, forward: Float::INFINITY).count { |_, offset| offset.abs <= OVERLAP_M }.fdiv(line.size)
  end

  # [[first, last], ...] bins where under GAP_SUPPORT of the trips have a real
  # fix, inner ones only (a stretch at an end is not between fixes)
  def gaps(share)
    runs = []
    start = nil
    share.each_with_index do |v, i|
      start ||= i if v < GAP_SUPPORT
      next unless start && (v >= GAP_SUPPORT || i == share.size - 1)

      stop = v < GAP_SUPPORT ? i : i - 1
      runs << [start, stop] if start.positive? && stop < share.size - 1 && (stop - start + 1) * BIN >= GAP_MIN_M
      start = nil
    end
    runs
  end

  def store(routes)
    TrackCorridor.transaction do
      TrackCorridor.where(user_id: @user.id).delete_all
      routes.each do |r|
        coords = r.line.map { |x, y| r.frame.lonlat(x, y) }
        TrackCorridor.create!(
          user_id: @user.id, mode: r.mode, trips: r.trips, track_ids: r.track_ids,
          path: "SRID=4326;LINESTRING(#{coords.map { |lon, lat| "#{lon.round(7)} #{lat.round(7)}" }.join(', ')})",
          length_m: G.length(r.line).round, spread_p50: r.spread_p50, spread_p90: r.spread_p90, gaps: r.gaps,
          filled: r.filled
        )
      end
    end
  end
end
