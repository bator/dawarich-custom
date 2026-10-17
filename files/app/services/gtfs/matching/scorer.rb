# frozen_string_literal: true

# Spec 9.4-9.6: scores one candidate trip against one window.
#
# Features (0..1 each, weights in Gtfs::Config::WEIGHTS):
#   shape      mean/median distance of the ride points from the trip geometry (0 m -> 1, >= 80 m -> 0)
#   time       schedule fit: each point is compared with the time the vehicle is
#              scheduled to be at that point's position (the 9.5 time-distance
#              curve, measured on the time axis so buses and trains are treated
#              alike). The trip is shifted by a delay in OFFSET_STEP_SECS steps
#              within +/-TIME_TOLERANCE_SECS; the best shift is the estimated delay.
#   stops      distance of the first/last points from the boarding/alighting stop
#   direction  share of steps that move forward along the trip
#   coverage   share of the ride time covered by points (gaps up to COVERAGE_GAP_SECS count)
#
# Stop mode (trip without a usable shape, spec 4.x "railway shapes may be
# missing"): the straight lines between stops are only good for ordering the
# points, they can be kilometres away from the track. Then
#   shape = share of the intermediate stops the points pass within
#           STOP_PASS_RADIUS_M (left out, like in gap mode, when the trip has
#           no intermediate stop on the ride). Whether the train stopped there is not
#           checked: reconstructed tracks (e.g. snapped train rides) have no
#           dwell. And
#   time  = the same delay fit, but on the times the points pass the stops
#           (last fix at the boarding stop, closest fix at each intermediate
#           stop compared with its [arrival, departure], first fix at the
#           alighting stop), where the scheduled position is exact.
#   Points farther than STOP_MODE_MAX_CROSS_M (or STOP_MODE_CROSS_SHARE of
#   the stop-to-stop leg they are on; real railways bend up to ~12 % away
#   from a 55 km chord) from the straight line between the stops are off the
#   line: more than OFF_LINE_SHARE of them rejects the trip (review K1).
#   Off-line points stay in the ride: real legs can leave the chord by far
#   more (Kelenföld - Érd alsó: 4.6 km on 11.9 km, 15 % of the ride), and
#   they are still part of the journey. Without an intermediate
#   stop nothing checks the path, so such a ride is capped below AUTO_ACCEPT
#   (uncertain, cap `no_intermediate_stops`).
#
# Dwell (review K2, buses/trams/trolleybuses with a shape and a dense track):
# a car or bike on the same road at the same time fits shape and schedule as
# well as the bus, but does not stop at the stops. When the points stand
# still near fewer than MIN_DWELL_SHARE of the intermediate stops the ride is
# capped below AUTO_ACCEPT (cap `no_dwell`); it is not rejected, because
# buses skip request stops.
#
# Rail with a shape (e.g. pfaedle-matched MÁV shapes, Gtfs::ShapeOverlay):
# the shape feature uses the shape, the time feature the stop passages as in
# stop mode (see #rail_timing?).
#
# Trains do not leave early: in stop mode a departure more than
# EARLY_DEPARTURE_REJECT_SECS before the timetable rejects the trip, unless
# the boarding time is a GPS gap edge (window.board_from_gap or a gap
# window), which says nothing about when the train left. For rail the
# departure is the start of the movement: the first step from
# window.moving_start on that moves away from the boarding stop, forward
# along the trip, faster than RAIL_DEPARTURE_MIN_KMH confirms it (platform
# walking does not), and the time is traced back to the last stationary fix
# within the radius before it. Only MÁV-type rail (mode 'rail') uses this;
# HÉV ('suburban') and trams keep the nearest-fix logic, and on a sparse
# track whose first moving point is beyond 2 x radius it falls back too.
#
# Sparse / low coverage (10-15 rides 17, 18; not in gap mode): coverage is
# proportional (each step counts up to the gap limit); only practically no
# coverage (< REJECT_COVERAGE) rejects; coverage below MIN_CERTAIN_COVERAGE, fewer than one
# point per SECS_PER_POINT_CERTAIN or fewer than MIN_CERTAIN_POINTS points cap
# the ride below AUTO_ACCEPT, and so does a window truncated by points dropped
# for low accuracy (window.truncated). On a sparse ride (window.sparse from the
# detector, else the median spacing of the ride points above
# SPARSE_MEDIAN_SPACING_SECS) the limit is SPARSE_COVERAGE_GAP_SECS.
#
# Delay (review K6): the offset search prefers a late train over an early one
# (early departures are rare), and the delay penalty is lower for late trips.
#
# Gap mode (9.6): when the ride has (almost) no points, e.g. underground, the
# shape and direction features cannot be evaluated; their weight is
# redistributed, the time feature compares the elapsed time with the
# scheduled ride time (+/-GAP_DURATION_TOLERANCE plus GAP_ACCESS_SLACK_SECS for
# walking to and from the platform) and the result is multiplied by GAP_FACTOR.
#
# Underground metro (gap mode on a metro trip; a metro trip is also scored in
# gap mode when its points cover less than METRO_SPARSE_COVERAGE of the ride,
# e.g. a shallow line with a few rough fixes): no GPS in the tunnel is what a
# metro ride looks like, not a sign of a bad match, so
#   - coverage is left out (it is 0 for every underground ride),
#   - the access time is METRO_ACCESS_SLACK_SECS (stairs, escalators and the
#     platform wait) and costs nothing within that slack,
#   - the few rough fixes inside the gap (shallow tunnels, stations near the
#     surface, the surfacing part of a line) become the `fixes` feature: each
#     fix counts as on the line within its own accuracy and is compared with
#     the schedule at its position; fixes are weighted by
#     METRO_FIX_MIN_ACCURACY_M / accuracy,
#   - the GAP_FACTOR discount shrinks with the evidence of those fixes:
#     GAP_FACTOR + (1 - GAP_FACTOR) * evidence * fixes, evidence = sum of the
#     fix weights / METRO_FIX_FULL_WEIGHT (at most 1). Without fixes the
#     ride keeps the plain GAP_FACTOR, with fixes off the line or off the
#     schedule the fixes feature itself pulls the score down.
class Gtfs::Matching::Scorer
  Score = Struct.new(:candidate, :profile, :confidence, :features, :delay_secs, :started_at, :ended_at,
                     :point_ids, :distance_m, :gap_mode, :stop_mode, :board, :alight, :rejected, :caps, :raw_confidence,
                     keyword_init: true)

  ALONG_MARGIN = 100 # metres around the boarding/alighting stop that still belong to the ride
  INNER_MARGIN = 20
  MOVEMENT_MIN_STEP_M = Gtfs::Config::MOVEMENT_MIN_STEP_M
  MOVEMENT_STILL_SPEED_MS = Gtfs::Config::MOVEMENT_STILL_SPEED_MS
  MOVEMENT_MAX_STEP_SECS = Gtfs::Config::MOVEMENT_MAX_STEP_SECS

  def initialize(window, candidate, profile)
    @window = window
    @candidate = candidate
    @profile = profile
    @day_start = candidate.day_start.to_i
  end

  def call
    return reject('trip geometry unusable') unless @profile.usable?

    @board = @profile.stop_at(@candidate.board_seq)
    @alight = @profile.stop_at(@candidate.alight_seq)
    return reject('stops not found') if @board.nil? || @alight.nil? || @alight.along <= @board.along

    project_points
    return reject('no points along the trip') if @ride.empty?
    return reject('path leaves the line between the stops') unless on_line?

    features = {}
    unless gap_mode?
      shape = stop_mode? ? stop_visit_score : shape_score
      features[:shape] = shape if shape
    end
    time = if gap_mode? then endpoint_time_score
           elsif stop_mode? || rail_timing? then stop_passage_time_score
           else curve_time_score
           end
    return reject(time[:reason]) if time[:reason]

    features[:time] = time[:score]
    features[:stops] = stops_score
    features[:direction] = direction_score unless gap_mode?
    features[:coverage] = coverage_score unless underground_metro?
    fixes = underground_metro? ? fixes_evidence(time[:delay]) : nil
    features[:fixes] = fixes[:score] if fixes

    return reject('schedule does not fit', features) if features[:time] < Gtfs::Config::MIN_TIME_SCORE
    if !gap_mode? && coverage_score < Gtfs::Config::REJECT_COVERAGE
      return reject('points cover too little of the ride', features)
    end
    if features[:shape] && features[:shape] < Gtfs::Config::MIN_SHAPE_SCORE
      return reject('path does not follow the trip', features)
    end

    weights = Gtfs::Config::WEIGHTS.slice(*features.keys)
    confidence = features.sum { |key, value| weights[key] * value } / weights.values.sum
    confidence *= gap_factor(fixes) if gap_mode?
    raw = confidence
    caps = confidence_caps(features)
    confidence = [confidence, Gtfs::Config::AUTO_ACCEPT - 0.01].min if caps.any?

    Score.new(candidate: @candidate, profile: @profile, confidence: confidence.round(3), raw_confidence: raw.round(3),
              features: features.transform_values { |v| v.round(3) }, delay_secs: time[:delay],
              started_at: ride_start, ended_at: ride_end, point_ids: @ride.map { |p| p[:point].id },
              distance_m: (@alight.along - @board.along).round, gap_mode: gap_mode?, stop_mode: stop_mode?,
              board: @board, alight: @alight, rejected: nil, caps:)
  end

  private

  def reject(reason, features = {})
    Score.new(candidate: @candidate, profile: @profile, confidence: 0.0, raw_confidence: 0.0, features:,
              rejected: reason)
  end

  def project_points
    from = @board.along - ALONG_MARGIN
    to = @alight.along + ALONG_MARGIN
    @ride = @window.points.filter_map do |point|
      along, cross = @profile.project(point.lon, point.lat, from: [from - 200, 0].max, to: to + 200)
      next if along.nil? || along < from || along > to

      { point:, along:, cross:, t: point.ts - @day_start }
    end
  end

  # Stop mode only (review K1): false when too many points are off the line.
  def on_line?
    return true unless @profile.shape_source == 'stops'

    legs = [@board, *intermediate_calls, @alight].map(&:along).each_cons(2).to_a
    off = @ride.count { |r| r[:cross] > off_line_bound(legs, r[:along]) }
    off < 3 || off <= Gtfs::Config::OFF_LINE_SHARE * @ride.size
  end

  def off_line_bound(legs, along)
    from, to = legs.find { |_a, b| along <= b } || legs.last
    [Gtfs::Config::STOP_MODE_MAX_CROSS_M, Gtfs::Config::STOP_MODE_CROSS_SHARE * (to - from)].max
  end

  def confidence_caps(features = {})
    caps = []
    caps << 'no_intermediate_stops' if stop_mode? && intermediate_calls.empty?
    share = dwell_share
    caps << 'no_dwell' if share && share < Gtfs::Config::MIN_DWELL_SHARE
    caps.concat(density_caps) unless gap_mode?
    caps << 'truncated_window' if @window.truncated && !truncation_harmless?(features)
    caps
  end

  # Only a truncated START is harmless (review K1): a track cut short at
  # the end can fit an earlier alighting stop perfectly, so an end
  # truncation (or an unknown side) keeps the cap, unless the ride ends at
  # the trip's terminus (#ends_at_terminus?). Privacy-zone cuts never
  # set `truncated` (A1).
  # Review 10-16 b: a dense ride that covers the trip and follows its shape
  # is not made uncertain by a dropped low-accuracy fix next to it (IC 849,
  # users 2 and 7: raw 0.95, shape 0.97, coverage 1.0 were capped to 0.74).
  # Only a real shape counts: stop mode's stop-visit share says too little.
  def truncation_harmless?(features)
    return false unless @window.truncated_start || @window.truncated_end
    return false if @window.truncated_end != false && !ends_at_terminus?

    !sparse_ride? && !gap_mode? && !stop_mode? &&
      features[:coverage].to_f >= Gtfs::Config::TRUNCATED_EXEMPT_MIN_COVERAGE &&
      features[:shape].to_f >= Gtfs::Config::TRUNCATED_EXEMPT_MIN_SHAPE
  end

  # An end truncation cannot hide a later alighting stop when the ride
  # alights at the trip's last stop and the last fix is within the boarding
  # radius of it (review K1, second option): nothing lies beyond.
  def ends_at_terminus?
    last = @window.points.last
    @alight.sequence == @profile.stops.last.sequence &&
      Gtfs::Matching::Geo.haversine(last.lon, last.lat, @alight.lon, @alight.lat) <= board_radius
  end

  def density_caps
    caps = []
    caps << 'low_coverage' if coverage_score < Gtfs::Config::MIN_CERTAIN_COVERAGE
    duration = ride_end - ride_start
    if duration.positive? && @ride.size < duration.fdiv(Gtfs::Config::SECS_PER_POINT_CERTAIN)
      caps << 'sparse_points'
    end
    caps << 'few_points' if @ride.size < Gtfs::Config::MIN_CERTAIN_POINTS
    caps
  end

  def sparse_ride?
    return @sparse_ride if defined?(@sparse_ride)

    @sparse_ride = if @window.sparse.nil?
                     Gtfs::Matching::WindowDetector::Window.sparse_points?(@ride.map { |r| r[:point] })
                   else
                     @window.sparse
                   end
  end

  # Share of the intermediate stops with a standing fix within DWELL_RADIUS_M,
  # or nil when it cannot be judged (not a bus/tram, no shape, sparse track,
  # fewer than DWELL_MIN_CALLS stops).
  def dwell_share
    return nil if gap_mode? || stop_mode? || !dwell_route?

    calls = intermediate_calls
    return nil if calls.size < Gtfs::Config::DWELL_MIN_CALLS || !dense_track?

    calls.count { |call| dwelled?(call) }.fdiv(calls.size)
  end

  def dwell_route?
    Gtfs::Config::DWELL_ROUTE_TYPES.include?(@profile.route&.route_type)
  end

  def dense_track?
    intervals = @ride.each_cons(2).map { |a, b| b[:point].ts - a[:point].ts }.sort
    intervals.any? && intervals[intervals.size / 2] <= Gtfs::Config::DWELL_MAX_SAMPLE_SECS
  end

  def dwelled?(call)
    @ride.any? do |r|
      standing?(r[:point]) &&
        Gtfs::Matching::Geo.haversine(r[:point].lon, r[:point].lat, call.lon, call.lat) <= Gtfs::Config::DWELL_RADIUS_M
    end
  end

  def ride_start = @window.gap? ? @window.start_ts : @ride.first[:point].ts
  def ride_end = @window.gap? ? @window.end_ts : @ride.last[:point].ts

  def inner_points
    @inner_points ||= @ride.select do |r|
      r[:along] > @board.along + INNER_MARGIN && r[:along] < @alight.along - INNER_MARGIN
    end
  end

  def underground_metro?
    return @underground_metro if defined?(@underground_metro)

    @underground_metro = gap_mode? && metro_trip?
  end

  def gap_factor(fixes)
    base = Gtfs::Config::GAP_FACTOR
    return base unless fixes

    base + ((1.0 - base) * fixes[:evidence] * fixes[:score])
  end

  # Underground metro: how well the fixes inside the gap fit the trip, each
  # within its own accuracy and at the delay found by the time feature.
  # => { score:, evidence: } or nil without fixes
  def fixes_evidence(delay)
    return nil if inner_points.empty?

    min_accuracy = Gtfs::Config::METRO_FIX_MIN_ACCURACY_M
    fits = inner_points.map do |r|
      tolerance = [r[:point].accuracy.to_f, min_accuracy].max
      on_line = 1.0 - ((r[:cross] - tolerance) / (2 * tolerance)).clamp(0.0, 1.0)
      on_time = 1.0 - (fix_time_error(r, delay) / Gtfs::Config::TIME_ERROR_MAX_SECS).clamp(0.0, 1.0)
      [min_accuracy / tolerance, on_line * on_time]
    end
    weight = fits.sum(&:first)
    { score: fits.sum { |w, fit| w * fit } / weight,
      evidence: (weight / Gtfs::Config::METRO_FIX_FULL_WEIGHT).clamp(0.0, 1.0) }
  end

  def fix_time_error(ride_point, delay)
    outside(ride_point[:t] - delay.to_i, *@profile.scheduled_interval(ride_point[:along], @board, @alight))
  end

  def gap_mode?
    return @gap_mode if defined?(@gap_mode)

    @gap_mode = @window.gap? || inner_points.size < 2 || large_internal_gap? || sparse_metro?
  end

  def metro_trip?
    TransitSegment.mode_for(@profile.route&.route_type) == 'metro'
  end

  def sparse_metro?
    metro_trip? && strict_metro_coverage < Gtfs::Config::METRO_SPARSE_COVERAGE
  end

  # The pre-sparse-fix all-or-nothing coverage (steps up to COVERAGE_GAP_SECS),
  # kept for the metro gap-mode decision so that proportional coverage does
  # not change which metro rides are scored as underground.
  def strict_metro_coverage
    duration = ride_end - ride_start
    return 0.0 if @window.gap? || !duration.positive?

    covered = @ride.each_cons(2).sum do |x, y|
      dt = y[:point].ts - x[:point].ts
      dt <= Gtfs::Config::COVERAGE_GAP_SECS ? dt : 0
    end
    covered.fdiv(duration).clamp(0.0, 1.0)
  end

  def large_internal_gap?
    duration = ride_end - ride_start
    return false unless duration.positive?

    gaps = @ride.each_cons(2).map { |a, b| b[:point].ts - a[:point].ts }
    longest = gaps.max || 0
    longest >= Gtfs::Config::GAP_MODE_MIN_SECS && longest.fdiv(duration) >= 0.4
  end

  def stop_mode?
    !gap_mode? && @profile.shape_source == 'stops'
  end

  # Railway trips with a (map-matched) shape: the shape checks the path, but
  # the time is still taken where the timetable is exact, at the stops. Trains
  # run late by different amounts along the line and make up time at stops,
  # which one offset on the time-distance curve cannot follow (stop timing
  # was verified on the real rides; GTFS_MATCH_RAIL_STOP_TIMING=false turns
  # this off).
  def rail_timing?
    Gtfs::Config::RAIL_STOP_TIMING && !gap_mode? && @profile.shape_source == 'shape' &&
      TransitSegment.mode_for(@profile.route&.route_type) == 'rail'
  end

  def intermediate_calls
    @profile.stops.select { |c| c.sequence > @board.sequence && c.sequence < @alight.sequence }
  end

  # [distance, ts] of the window point closest to a stop call
  def closest_pass(call)
    @window.points.map { |p| [Gtfs::Matching::Geo.haversine(p.lon, p.lat, call.lon, call.lat), p.ts] }.min_by(&:first)
  end

  def stop_visit_score
    calls = intermediate_calls
    return nil if calls.empty? # nothing to check: the feature is left out (weights renormalised)

    calls.count { |c| closest_pass(c).first <= Gtfs::Config::STOP_PASS_RADIUS_M }.fdiv(calls.size)
  end

  # Schedule fit at the stops. Unlike a bus on a short ride, a train's delay
  # often grows along the way, so every stop has its own delay and the error
  # counts only what a real train does not do: leaving a stop early, arriving
  # at the end much too early, or making up more than DELAY_RECOVERY_SLACK.
  # The reported delay is the largest one. Falls back to the endpoint
  # comparison when fewer than two stops were seen.
  def stop_passage_time_score
    samples = stop_passage_samples
    return endpoint_time_score if samples.size < 2

    # a sample may carry an uncertain time [t, t_late] (sparse departure):
    # it fits when the scheduled time lies anywhere in that interval
    delays = samples.map do |t, lo, hi, t_late|
      t_late ||= t
      if t_late < lo then t_late - lo
      elsif t > hi then t - hi
      else 0
      end
    end
    tol = Gtfs::Config::TIME_TOLERANCE_SECS
    return { reason: 'delay outside the tolerance' } if delays.any? { |d| d.abs > tol }
    # trains do not leave early: with only two stops seen, averaging would
    # hide it behind the arrival slack (review K1)
    if @departure_seen && !board_from_gap? && delays.first < -Gtfs::Config::EARLY_DEPARTURE_REJECT_SECS
      return { reason: 'left before the timetable' }
    end

    error = delays.each_with_index.sum do |delay, i|
      slack = i == delays.size - 1 ? Gtfs::Config::EARLY_ARRIVAL_SLACK : Gtfs::Config::EARLY_DEPARTURE_SLACK
      [-delay - slack, 0].max
    end
    error += delays.each_cons(2).sum { |a, b| [a - b - Gtfs::Config::DELAY_RECOVERY_SLACK, 0].max }
    delay = delays.max_by(&:abs)
    { score: time_value(error.fdiv(delays.size), delay), delay: delay.round }
  end

  def stop_passage_samples
    radius = Gtfs::Config::STOP_PASS_RADIUS_M
    samples = []
    departed = departure_ts(@board, radius)
    @departure_seen = departed.present?
    if departed
      late = sparse_departure_latest(departed)
      samples << [departed - @day_start, @board.departure_secs, @board.departure_secs, late && (late - @day_start)]
    end
    intermediate_calls.each do |call|
      distance, ts = closest_pass(call)
      samples << [ts - @day_start, call.arrival_secs, call.departure_secs] if distance <= radius
    end
    arrived = arrival_ts(@alight, radius)
    samples << [arrived - @day_start, @alight.arrival_secs, @alight.arrival_secs] if arrived
    samples
  end

  # Departure: the last fix standing (or else the last fix at all) within the
  # radius of the stop, before the points move away from it.
  def departure_ts(call, radius)
    moving = rail_trip? && rail_departure_point(call, radius)
    return moving.ts if moving

    near = near_run(@window.points, call, radius)
    (near.reverse.find { |p| standing?(p) } || near.last)&.ts
  end

  # Sparse ride (review 10-16 a): the last fix near the boarding stop can be
  # many minutes before the train left (user 1: 07:29:46 for a 07:41 train),
  # so the departure is only known to lie between that fix and the next one.
  # The latest possible departure is estimated from the next fix: its
  # distance from the stop divided by the speed of the step after it (else
  # the step to it), clamped into [departed, next fix]. Returns that time, or
  # nil when the ride is dense or there is no next fix.
  def sparse_departure_latest(departed)
    return nil unless sparse_ride? && !board_from_gap?

    points = @window.points
    index = points.index { |p| p.ts == departed }
    following = index && points[index + 1]
    return nil unless following

    after = points[index + 2]
    speed = after ? step_speed(following, after) : step_speed(points[index], following)
    distance = Gtfs::Matching::Geo.haversine(following.lon, following.lat, @board.lon, @board.lat)
    estimate = speed.positive? && speed.finite? ? following.ts - (distance / speed) : departed
    estimate.clamp(departed, following.ts).round
  end

  # Arrival: the first fix standing (or else the first fix) near the last stop.
  def arrival_ts(call, radius)
    near = near_run(@window.points.reverse, call, radius).reverse
    (near.find { |p| standing?(p) } || near.first)&.ts
  end

  # The fixes within the radius from the start of `points` until they are
  # clearly away (2 x radius) from the stop.
  def near_run(points, call, radius)
    run = []
    points.each do |p|
      d = Gtfs::Matching::Geo.haversine(p.lon, p.lat, call.lon, call.lat)
      if d <= radius
        run << p
      elsif run.any? && d > 2 * radius
        break
      end
    end
    run
  end

  def board_from_gap?
    @window.gap? || @window.board_from_gap.present?
  end

  def rail_trip?
    TransitSegment.mode_for(@profile.route&.route_type) == 'rail'
  end

  # Rail departure = the start of the movement. From the first moving point
  # on (within 2 x radius of the stop) the first step that leaves the stop,
  # goes forward along the trip and is faster than RAIL_DEPARTURE_MIN_KMH only
  # CONFIRMS that the train moves; the departure is then traced back to the
  # last stationary point within the radius before that step (a slowly
  # accelerating train reaches the speed threshold only ~30 s after leaving,
  # which would hide an early departure, review K1).
  def rail_departure_point(call, radius)
    return nil unless @window.moving_start

    points = @window.points
    (@window.moving_start...(points.size - 1)).each do |i|
      p = points[i]
      from_stop = Gtfs::Matching::Geo.haversine(p.lon, p.lat, call.lon, call.lat)
      return nil if from_stop > 2 * radius
      return movement_start(points, i, call, radius) if departing_step?(p, points[i + 1], call, from_stop)
    end
    nil
  end

  # Walks back from the confirming point through a dense (steps of at most
  # MOVEMENT_MAX_STEP_SECS), accelerating run: each earlier point is within
  # the radius, closer to the stop and reached with a slower step. Stops at a
  # fix standing still. Walking on the platform is neither dense-accelerating
  # nor continuous with the train, so it ends the run.
  def movement_start(points, index, call, radius)
    distance = ->(pt) { Gtfs::Matching::Geo.haversine(pt.lon, pt.lat, call.lon, call.lat) }
    start = index
    while start.positive?
      current = points[start]
      previous = points[start - 1]
      break if current.ts - previous.ts > MOVEMENT_MAX_STEP_SECS || distance.call(previous) > radius
      break unless distance.call(previous) < distance.call(current) - MOVEMENT_MIN_STEP_M
      break if start + 1 < points.size && start < index &&
               step_speed(previous, current) >= step_speed(current, points[start + 1])

      start -= 1
      break if standing_still?(previous)
    end
    points[start]
  end

  def step_speed(from, to)
    dt = to.ts - from.ts
    dt.positive? ? Gtfs::Matching::Geo.haversine(from.lon, from.lat, to.lon, to.lat) / dt : Float::INFINITY
  end

  # a reported speed of (almost) zero: the train had not started yet
  def standing_still?(point)
    point.speed && point.speed <= MOVEMENT_STILL_SPEED_MS
  end

  def departing_step?(point, following, call, from_stop)
    dt = following.ts - point.ts
    return false unless dt.positive?

    kmh = Gtfs::Matching::Geo.haversine(point.lon, point.lat, following.lon, following.lat) / dt * 3.6
    a, = @profile.project(point.lon, point.lat)
    b, = @profile.project(following.lon, following.lat)
    kmh >= Gtfs::Config::RAIL_DEPARTURE_MIN_KMH && a && b && b > a &&
      Gtfs::Matching::Geo.haversine(following.lon, following.lat, call.lon, call.lat) > from_stop
  end

  def standing?(point)
    point.speed && point.speed <= Gtfs::Config::STOP_SLOW_SPEED_MS
  end

  def shape_score
    distances = @ride.map { |r| r[:cross] }.sort
    mean = distances.sum / distances.size
    median = distances[distances.size / 2]
    1.0 - ((mean + median) / 2 / Gtfs::Config::SHAPE_MAX_DISTANCE_M).clamp(0.0, 1.0)
  end

  def curve_time_score
    samples = inner_points.map { |r| [r[:t], *@profile.scheduled_interval(r[:along], @board, @alight)] }
    delay, error = best_offset { |offset| samples.sum { |t, lo, hi| outside(t - offset, lo, hi) } / samples.size }
    { score: time_value(error, delay), delay: }
  end

  def endpoint_time_score
    first_t = ride_start - @day_start
    last_t = ride_end - @day_start
    scheduled = @alight.arrival_secs - @board.departure_secs
    elapsed = last_t - first_t
    return { reason: 'scheduled ride time unknown' } unless scheduled.positive?

    tolerance = Gtfs::Config::GAP_DURATION_TOLERANCE * scheduled
    slack = access_slack
    too_short = elapsed < scheduled - tolerance
    too_long = elapsed > scheduled + tolerance + slack
    return { reason: "elapsed #{elapsed}s does not fit scheduled #{scheduled}s" } if too_short || too_long

    endpoint_error = lambda do |offset|
      [(first_t - offset) - @board.departure_secs, 0].max + [@alight.arrival_secs - (last_t - offset), 0].max
    end
    delay, = best_offset { |offset| endpoint_error.call(offset) + fix_offset_error(offset) }
    { score: time_value(endpoint_error.call(delay), delay) * (1.0 - (0.5 * gap_excess(elapsed, scheduled, tolerance))),
      delay: }
  end

  def access_slack
    underground_metro? ? Gtfs::Config::METRO_ACCESS_SLACK_SECS : Gtfs::Config::GAP_ACCESS_SLACK_SECS
  end

  # How far the elapsed time is off the scheduled one (0..1). Underground
  # metro: the access time within the slack is expected and costs nothing.
  def gap_excess(elapsed, scheduled, tolerance)
    excess = if elapsed <= scheduled then (scheduled - elapsed).fdiv(tolerance)
             elsif underground_metro? then [elapsed - scheduled - access_slack, 0].max.fdiv(tolerance)
             else (elapsed - scheduled).fdiv(tolerance + access_slack)
             end
    excess.clamp(0.0, 1.0)
  end

  # Underground metro: the fixes inside the gap also say where the train was
  # when, so they help to find the delay.
  def fix_offset_error(offset)
    return 0 unless underground_metro? && inner_points.any?

    inner_points.sum { |r| fix_time_error(r, offset) }.fdiv(inner_points.size)
  end

  # Tries every offset; returns [offset, error] with the smallest error
  # (ties: the smaller absolute offset, then late before early).
  def best_offset
    tol = Gtfs::Config::TIME_TOLERANCE_SECS
    step = Gtfs::Config::OFFSET_STEP_SECS
    candidates = (-tol..tol).step(step).map { |offset| [offset, yield(offset)] }
    candidates.min_by { |offset, error| [error, offset.abs, -offset] }
  end

  def time_value(error, delay)
    fit = 1.0 - (error / Gtfs::Config::TIME_ERROR_MAX_SECS).clamp(0.0, 1.0)
    penalty = delay.negative? ? Gtfs::Config::DELAY_PENALTY : Gtfs::Config::LATE_DELAY_PENALTY
    fit * (1.0 - (penalty * delay.abs.fdiv(Gtfs::Config::TIME_TOLERANCE_SECS)))
  end

  def outside(time, low, high)
    return low - time if time < low
    return time - high if time > high

    0.0
  end

  def stops_score
    start_points = endpoint_points(@window.points)
    end_points = endpoint_points(@window.points.reverse)
    [stop_proximity(start_points, @board), stop_proximity(end_points, @alight)].sum / 2
  end

  def endpoint_points(points)
    first = points.first
    points.take_while { |p| (p.ts - first.ts).abs <= Gtfs::Config::ENDPOINT_SECS }
          .first(Gtfs::Config::ENDPOINT_POINTS)
  end

  def stop_proximity(points, stop)
    distance = points.map { |p| Gtfs::Matching::Geo.haversine(p.lon, p.lat, stop.lon, stop.lat) }.min
    1.0 - (distance / (board_radius * 1.5)).clamp(0.0, 1.0)
  end

  def board_radius
    rail = Gtfs::Config::RAIL_ROUTE_TYPES.include?(@profile.route&.route_type)
    rail ? Gtfs::Config::RAIL_BOARD_RADIUS_M : Gtfs::Config::BOARD_RADIUS_M
  end

  def direction_score
    steps = @ride.each_cons(2).map { |a, b| b[:along] - a[:along] }
    return 1.0 if steps.empty?

    steps.count { |d| d >= -Gtfs::Config::DIRECTION_SLACK_M }.fdiv(steps.size)
  end

  def coverage_score
    duration = ride_end - ride_start
    return 0.0 if @window.gap? || !duration.positive?

    limit = sparse_ride? ? Gtfs::Config::SPARSE_COVERAGE_GAP_SECS : Gtfs::Config::COVERAGE_GAP_SECS
    # proportional: a longer step covers `limit` of it, not nothing (no cliff)
    covered = @ride.each_cons(2).sum { |a, b| [b[:point].ts - a[:point].ts, limit].min }
    covered.fdiv(duration).clamp(0.0, 1.0)
  end
end
