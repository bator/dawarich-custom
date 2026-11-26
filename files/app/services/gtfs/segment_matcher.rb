# frozen_string_literal: true

# Spec 9 (Phase 2): matches a user's points against the GTFS timetables and
# returns the detected rides. Pure read; saving is done by
# Gtfs::SegmentWriter. Pseudocode 9.11:
#
#   points  = load_points(user, from, to)                  # 9.1 PointLoader
#   windows = detect_movement_windows(points)               # 9.2 WindowDetector
#   for window: for feed: for service_date in [local date, previous day]:
#       candidates = find_trips(...)                        # 9.3 CandidateFinder
#       score each candidate                                # 9.4-9.6 Scorer
#   pick the best (9.9: across all feeds), keep it if >= DROP_BELOW
#   a GPS gap next to a movement window is also scored together with it
#   a GPS gap between two movement windows is scored with both (a bridge)
#   join consecutive rides on the same trip and score them again as one
#   extend a ride into a movement window right after it on the same trip
#
# Windows are attributed to the range by their start time; points up to
# DAY_BUFFER_SECS outside the range are loaded so that rides crossing midnight
# are seen whole.
class Gtfs::SegmentMatcher
  Match = Struct.new(:score, :alternatives, :ambiguous, :trip_alternatives, :trip_ambiguous, :window_kind,
                     :window, keyword_init: true) do
    delegate :started_at, :ended_at, :confidence, to: :score
  end
  Result = Struct.new(:matches, :stats, keyword_init: true)

  OVERLAP_SECS = 30
  TRANSFER_BACK_SECS = 600 # a metro ride starting this soon after another ride may board at its stop
  TRANSFER_RADIUS_M = 400 # fixes this close to that ride's alighting stop are the change
  TRANSFER_WAIT_SECS = 1200 # waiting at the end of a gap before the next ride (gaps_before_transfers)
  TRANSFER_GAP_METRO_SHARE = 0.8 # metro_over_rail
  GAP_NEIGHBOUR_SECS = 60 # a gap window and a movement window this close share their edge point
  EXTEND_GAP_SECS = 300 # a movement window starting this soon after a ride may be its rest (a jam, 2026-11-25: 250 s)
  EXTEND_MAX_STEPS = 3
  # A train can stop short of the station (signal) and enter it after the
  # movement window has ended: look this far past the end of an unmatched window.
  ARRIVAL_LOOKAHEAD_SECS = 300
  ARRIVAL_LOOKAHEAD_STEP_M = 100 # try a later point only when it moved this far from the last try
  ARRIVAL_LOOKAHEAD_TRIES = 6
  EXTEND_ARRIVAL_MODES = %w[rail metro].freeze
  EXTEND_ARRIVAL_MAX_DROP = 0.15 # a longer ride may score this much lower than the cut one
  ARRIVAL_MAX_GAP_SECS = 1200 # one GPS gap this long (a metro underground) may lie in the lookahead
  # A bus can stand minutes at a stop after the one it was boarded at; look this far
  # before a bus or tram ride for the stretch it already drove (extend_departures).
  DEPARTURE_LOOKBEHIND_SECS = 420
  EXTEND_DEPARTURE_MODES = %w[bus tram].freeze
  DEPARTURE_MIN_KMH = 20.0 # that stretch: this fast (no walk or run for the bus) ...
  DEPARTURE_MIN_M = 80     # ... over this far (no multipath jump) ...
  DEPARTURE_SPAN_SECS = (10..40) # ... between two fixes this far apart
  DEPARTURE_BOARD_SECS = 90 # the retry starts this long before that stretch (the stop)
  DEPARTURE_CORRIDOR_M = 120 # shift_board: the stretch's fixes this close to the trip's line ...
  DEPARTURE_BACKSTEP_M = 40  # ... never this far back along it ...
  DEPARTURE_STOP_M = 250     # ... and the stop this far behind its first fix at most

  attr_reader :feed_set

  def initialize(user, feed_set: nil, privacy_zones: nil, logger: Rails.logger)
    @user = user
    @feed_set = feed_set || Gtfs::Matching::FeedSet.for_user(user)
    @privacy_zones = privacy_zones || Users::PrivacyZones.new(user).call
    @logger = logger
    @profiles = {}
  end

  def match(from_ts, to_ts)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stats = Hash.new(0)
    return Result.new(matches: [], stats: stats.merge('feeds' => 0)) if @feed_set.empty?

    buffer = Gtfs::Config::DAY_BUFFER_SECS
    loader = Gtfs::Matching::PointLoader.new(@user, from_ts - buffer, to_ts + buffer, privacy_zones: @privacy_zones)
    points = loader.call
    @stream = points
    windows = Gtfs::Matching::WindowDetector.new(points, dropped_ts: loader.dropped_accuracy_ts).call
                                            .select { |w| w.start_ts >= from_ts && w.start_ts < to_ts }
    @windows = windows
    stats['points'] = points.count { |p| p.ts >= from_ts && p.ts < to_ts }
    stats['windows'] = windows.size

    matches = match_windows(windows, stats)
    matches = merge_same_trip(drop_overlaps(matches), points, windows, stats)
    matches = extend_into_next(matches, points, windows, stats)
    # an arrival extended over the next gap can reach a ride matched in that gap on its own
    # (2026-11-17: M4 182 Bikás park -> Keleti and 183 Móricz -> Keleti, both kept)
    matches = drop_overlaps(extend_arrivals(matches, stats))
    matches = extend_boards(matches, stats)
    matches = gaps_before_transfers(matches, stats)
    matches = drop_overlaps(extend_departures(matches, stats))
    stats['matches'] = matches.size
    stats['ms'] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    Result.new(matches:, stats:)
  rescue StandardError => e
    @logger.error("[GTFS match] user #{@user.id}: #{e.class}: #{e.message}")
    raise
  end

  private

  def match_windows(windows, stats)
    matches = []
    index = 0
    while index < windows.size
      first, second, third = windows[index, 3]
      bridged = third && gap_bridge?(first, second, third) && match_gap_bridge(first, second, third, stats)
      if bridged
        matches.concat(bridged)
        index += 3
      elsif second && gap_neighbours?(first, second)
        matches.concat(match_gap_pair(first, second, stats))
        index += 2
      else
        matches.concat(match_window(first, 0, stats))
        index += 1
      end
    end
    matches
  end

  # A metro that surfaces between two stations (M2 after Pillangó utca, M3
  # after Határ út) or goes underground after the boarding stop leaves a gap
  # window whose far end is mid-line, away from any stop, next to a movement
  # window. Neither half alone is the ride; together they are. The pair is
  # scored as one window too, and that ride replaces the separate ones when
  # it is accepted and either nothing else matched, it is the same line as a
  # separate match (which it extends), or it scores at least as well.
  # The join is only allowed for a metro trip or when the gap's outer end
  # lies near the boarding/alighting stop (gap_join_allowed?): a train ride
  # whose GPS starts late must not be stretched back to a walk or a bus
  # stop (10-15 ride 17). When the gap comes first the boarding time is a
  # gap edge (board_from_gap), so the early-departure check is skipped.
  def gap_neighbours?(first, second)
    first.gap? != second.gap? && (second.start_ts - first.end_ts).abs <= GAP_NEIGHBOUR_SECS
  end

  def match_gap_pair(first, second, stats)
    separate = match_window(first, 0, stats) + match_window(second, 0, stats)
    window = Gtfs::Matching::WindowDetector::Window.new(points: (first.points + second.points).uniq(&:ts),
                                                        kind: :moving, pauses: [], board_from_gap: first.gap?,
                                                        truncated: first.truncated || second.truncated,
                                                        truncated_start: first.truncated_start,
                                                        truncated_end: second.truncated_end,
                                                        sparse: [first, second].any?(&:sparse))
    best, alternatives = evaluate(window, stats)
    return separate unless best && best.confidence >= drop_below(best)
    return separate unless gap_join_allowed?(first, second, best)
    return separate unless separate.empty? || separate.any? { |m| line_label(m.score) == line_label(best) } ||
                           best.confidence >= separate.map(&:confidence).max ||
                           train_through_gap?(separate, best, first.gap?)

    stats['gap_joins'] += 1
    [build_match(window, best, alternatives)]
  end

  # A movement alone scores higher than the whole ride because the gap lowers
  # the coverage, so the ride that stops where the fix was lost wins
  # (2026-11-05: Z30 to Kápolnásnyék 0.84, the 9796 to Székesfehérvár 0.76; the
  # phone sent only 1-5 km fixes for the last 21 km). The longer train ride is
  # taken when it is certain enough and shares the stop away from the gap: the
  # outer end was checked by gap_join_allowed?, so it runs on to a real stop.
  def train_through_gap?(separate, best, gap_first)
    return false unless separate.one? && mode_of(best) == 'rail' && mode_of(separate.first.score) == 'rail'
    return false if best.confidence < Gtfs::Config::MIN_CONFIDENCE

    score = separate.first.score
    gap_first ? same_stop?(score.alight, best.alight) : same_stop?(score.board, best.board)
  end

  # A train ride whose GPS drops out on the way (07:57-08:17 on 2026-10-22,
  # 36.5 km without a fix between Velence and Kelenföld) leaves movement, gap,
  # movement. The gap's far end is mid-line, so match_gap_pair does not join
  # it, and the first movement alone ended the ride where the fix was lost
  # (ride 133: Székesfehérvár -> Velence instead of Kelenföld; Bator). The
  # three are scored as one window too; that ride is taken when it is accepted
  # and picks the trip the first movement alone matched, so a ride is only
  # extended, never replaced by another line.
  # The first movement often matches nothing, because it ends between two
  # stations where the fix was lost (2026-11-05: 07:52 near Dinnyés, the 9057
  # was lost whole). With nothing to replace, a train ride is taken as well.
  def gap_bridge?(first, gap, last)
    !first.gap? && gap.gap? && !last.gap? && gap_neighbours?(first, gap) && gap_neighbours?(gap, last)
  end

  # 2026-11-17: Székesfehérvár 17:14 -> Kelenföld by train, a 12 min gap, then the train's
  # last part and, after a 5 min change at Kelenföld that the window detector did not cut, the
  # M4 to Móricz in the same movement window. The three ended mid-metro and had no candidate,
  # so the train was lost. The bridge is tried again with the last window cut at its longest
  # pause (the change); the rest after the cut is matched on its own.
  def match_gap_bridge(first, gap, last, stats)
    separate = match_window(first, 0, stats)
    bridged = bridge_match(first, gap, last, separate, stats)
    return bridged if bridged

    left, right = last.split
    return unless left && Gtfs::Matching::WindowDetector.long_enough?(right)

    bridged = bridge_match(first, gap, left, separate, stats, rail_only: true)
    return unless bridged

    stats['gap_bridge_cuts'] += 1
    bridged + match_window(right, 1, stats)
  end

  def bridge_match(first, gap, last, separate, stats, rail_only: false)
    window = Gtfs::Matching::WindowDetector::Window.new(points: (first.points + gap.points + last.points).uniq(&:ts),
                                                        kind: :moving, pauses: [], board_from_gap: false,
                                                        truncated: first.truncated || last.truncated,
                                                        truncated_start: first.truncated_start,
                                                        truncated_end: last.truncated_end,
                                                        sparse: [first, gap, last].any?(&:sparse))
    best, alternatives = evaluate(window, stats)
    return unless best && best.confidence >= drop_below(best)
    return if rail_only && mode_of(best) != 'rail'
    return unless separate.empty? ? mode_of(best) == 'rail' : separate.any? { |m| same_trip?(m.score, best) }

    stats['gap_bridges'] += 1
    [build_match(window, best, alternatives)]
  end

  def gap_join_allowed?(first, second, score)
    return true if mode_of(score) == 'metro'

    outer, stop = first.gap? ? [first.points.first, score.board] : [second.points.last, score.alight]
    Gtfs::Matching::Geo.haversine(outer.lon, outer.lat, stop.lon, stop.lat) <= Gtfs::Config::GAP_JOIN_STOP_RADIUS_M
  end

  def match_window(window, depth, stats)
    best, alternatives = evaluate(window, stats)
    accepted = best && best.confidence >= drop_below(best)
    return [build_match(window, best, alternatives)] if accepted && best.confidence >= Gtfs::Config::AUTO_ACCEPT

    # 2026-11-13: the whole window (Székesfehérvár 07:44 - 08:22) ended 500 m short of the
    # Kelenföld stop and had no candidate; its first half matched the 9057 to Velence, so the
    # late arrival below was never tried. A whole-window train ride comes before the halves.
    unless accepted || depth.positive?
      late = match_late_arrival(window, stats)
      return late if late.any?
    end

    halves = depth < Gtfs::Config::SPLIT_DEPTH ? split_matches(window, depth, stats) : []
    if use_halves?(halves, accepted ? best : nil)
      stats['split_windows'] += 1
      return halves
    end
    accepted ? [build_match(window, best, alternatives)] : []
  end

  # 2026-10-30: the 9057 stopped 660 m before the Kelenföld stop, 08:21-08:22,
  # and the window ended there, outside the 300 m stop radius, so the whole ride
  # had no candidate. The fixes reached the stop at 08:22:51, after the window.
  # An unmatched movement window is retried with the points just after it, up to
  # the first one that makes it an accepted train ride.
  def match_late_arrival(window, stats)
    return [] unless window.kind == :moving

    arrival_tries(window, stop_ts: next_movement_start(window)).each do |extra|
      longer = Gtfs::Matching::WindowDetector::Window.new(points: window.points + extra, kind: :moving,
                                                          pauses: window.pauses, moving_start: window.moving_start,
                                                          truncated: window.truncated,
                                                          truncated_start: window.truncated_start,
                                                          truncated_end: window.truncated_end, sparse: window.sparse)
      best, alternatives = evaluate(longer, stats)
      next unless best && best.confidence >= drop_below(best) && mode_of(best) == 'rail'

      stats['late_arrivals'] += 1
      return [build_match(longer, best, alternatives)]
    end
    []
  end

  # 2026-11-06 (M4): the ride ended at II. János Pál pápa tér, the last point of
  # its window; the next fix, 145 s later, was at Keleti but in no window.
  # 2026-11-07 (M4): from Keleti the window ended at Rákóczi tér, then 10 min
  # without a fix underground, then fixes 370 m from the Kelenföld stop (metro
  # radius 120 m), so the gap could not be joined. A matched ride is retried
  # with the points after it; the furthest try that stays on the same line,
  # alights at another stop and is accepted replaces it.
  def extend_arrivals(matches, stats)
    matches.map { |match| extend_arrival(match, matches, stats) || match }
  end

  def extend_arrival(match, matches, stats)
    window = match.window
    return if window.nil? || window.gap?
    return unless EXTEND_ARRIVAL_MODES.include?(mode_of(match.score)) # review 2026-11-15: no bus walking on

    next_start = matches.reject { |m| m.equal?(match) }.map { |m| m.started_at.to_i }.select { |t| t > window.end_ts }.min
    found = nil
    arrival_tries(window, stop_ts: next_start).each do |extra|
      longer = Gtfs::Matching::WindowDetector::Window.new(points: window.points + extra, kind: :moving,
                                                          pauses: window.pauses, moving_start: window.moving_start,
                                                          board_from_gap: window.board_from_gap,
                                                          truncated: window.truncated,
                                                          truncated_start: window.truncated_start,
                                                          truncated_end: window.truncated_end, sparse: window.sparse)
      best, alternatives = evaluate(longer, stats)
      next unless best && best.confidence >= drop_below(best) && line_label(best) == line_label(match.score)
      next unless same_stop?(best.board, match.score.board) &&
                  best.confidence >= match.confidence - EXTEND_ARRIVAL_MAX_DROP
      next if same_stop?(best.alight, match.score.alight) || best.ended_at.to_i <= match.ended_at.to_i

      found = build_match(longer, best, alternatives)
    end
    stats['extended_arrivals'] += 1 if found
    found
  end

  # 2026-11-17 (Bator: "kelenföldről mentem a keletibe"): IC 903 to Kelenföld 17:59, then the
  # M4 from Kelenföld vasútállomás. The fixes at the station (17:59-18:02) belonged to the
  # pause the window detector cut at, so the metro window started at the first fix
  # underground, near Bikás park, and the ride boarded there. A metro ride that starts soon
  # after another ride is retried with the fixes since that ride's end that lie near its
  # alighting stop (the change); taken when it is the same line to the same stop, boards
  # nearer to that stop and is accepted.
  def extend_boards(matches, stats)
    matches.each_with_index.map do |match, i|
      prev = i.positive? ? matches[i - 1] : nil
      (prev && extend_board(match, prev, stats)) || match
    end
  end

  def extend_board(match, prev, stats)
    window = match.window
    return if window.nil? || window.gap? || mode_of(match.score) != 'metro'

    change = match.started_at.to_i - prev.ended_at.to_i
    return unless change.between?(0, TRANSFER_BACK_SECS)

    stop = prev.score.alight or return
    near = ->(p) { Gtfs::Matching::Geo.haversine(p.lon, p.lat, stop.lon, stop.lat) <= TRANSFER_RADIUS_M }
    extra = @stream.select { |p| p.ts >= prev.ended_at.to_i && p.ts < window.start_ts && near.call(p) }
    return if extra.empty?

    longer = Gtfs::Matching::WindowDetector::Window.new(points: extra + window.points, kind: :moving,
                                                        pauses: [], board_from_gap: false,
                                                        truncated: window.truncated,
                                                        truncated_start: window.truncated_start,
                                                        truncated_end: window.truncated_end, sparse: window.sparse)
    best, alternatives = evaluate(longer, stats)
    return unless best && best.confidence >= drop_below(best) && line_label(best) == line_label(match.score)
    return unless same_stop?(best.alight, match.score.alight) && !same_stop?(best.board, match.score.board)
    return unless best.confidence >= match.confidence - EXTEND_ARRIVAL_MAX_DROP
    return unless Gtfs::Matching::Geo.haversine(best.board.lon, best.board.lat, stop.lon, stop.lat) <
                  Gtfs::Matching::Geo.haversine(match.score.board.lon, match.score.board.lat, stop.lon, stop.lat)

    stats['extended_boards'] += 1
    build_match(longer, best, alternatives)
  end

  # 2026-11-17 (Bator: "stefánia úttól busszal mentem hazáig"): bus 7 left Stefánia út /
  # Thököly út at 23:15 (the logger: 29 km/h for 20 s), then stood 4.5 min at Zugló
  # vasútállomás; the window detector took that stand for the wait at the stop, and the ride
  # boarded there, the 400 m before it counted as a walk. A bus or tram ride is retried with
  # the fixes of the DEPARTURE_LOOKBEHIND_SECS before it (not before the previous ride's end)
  # when they hold a vehicle-speed stretch (vehicle_stretch_at): walking on along the route
  # to the next stop, or running for the bus, never reaches it (review 2026-11-15: no bus
  # walking on), so a sparse phone keeps its ride as it was. Taken when it is the same line
  # to the same stop, boards at another stop earlier, and is accepted.
  def extend_departures(matches, stats)
    matches.each_with_index.map do |match, i|
      prev_end = i.positive? ? matches[i - 1].ended_at.to_i : nil
      extend_departure(match, prev_end, stats) || match
    end
  end

  def extend_departure(match, prev_end, stats)
    window = match.window
    return if window.nil? || window.gap? || !EXTEND_DEPARTURE_MODES.include?(mode_of(match.score))

    from = window.start_ts - DEPARTURE_LOOKBEHIND_SECS
    from = [from, prev_end].max if prev_end
    before = @stream.select { |p| p.ts >= from && p.ts < window.start_ts }
    fast_at = vehicle_stretch_at(before + window.points.first(1)) or return
    extra = before.select { |p| p.ts >= fast_at - DEPARTURE_BOARD_SECS }
    return if extra.empty?

    longer = Gtfs::Matching::WindowDetector::Window.new(points: extra + window.points, kind: :moving,
                                                        pauses: [], board_from_gap: false,
                                                        truncated: window.truncated,
                                                        truncated_start: window.truncated_start,
                                                        truncated_end: window.truncated_end, sparse: window.sparse)
    best, alternatives = evaluate(longer, stats)
    if best && best.confidence >= drop_below(best) && line_label(best) == line_label(match.score) &&
       same_stop?(best.alight, match.score.alight) && !same_stop?(best.board, match.score.board) &&
       best.started_at.to_i < match.started_at.to_i && best.confidence >= match.confidence - EXTEND_ARRIVAL_MAX_DROP
      stats['extended_departures'] += 1
      return build_match(longer, best, alternatives)
    end

    shifted = shift_board(match, before, fast_at) or return
    stats['shifted_boards'] += 1
    shifted
  end

  # When the longer window fits no timetable (the bus stood minutes at a stop on the way:
  # 2026-11-17, bus 7 at Zugló vasútállomás), the ride keeps its trip and score and only its
  # boarding moves back to the earlier stop of the same trip where the vehicle-speed stretch
  # starts: every fix from there to the ride lies within DEPARTURE_CORRIDOR_M of the trip's
  # line and moves on along it, and the stop lies DEPARTURE_STOP_M or less behind the first.
  def shift_board(match, before, fast_at)
    score = match.score
    profile = score.profile
    return unless profile.respond_to?(:usable?) && profile.usable? && score.board

    run = before.select { |p| p.ts >= fast_at }
    return if run.empty?

    alongs = run.map { |p| profile.project(p.lon, p.lat) }
    return unless alongs.all? { |_, d| d <= DEPARTURE_CORRIDOR_M }
    return unless alongs.each_cons(2).all? { |(a, _), (b, _)| b >= a - DEPARTURE_BACKSTEP_M }

    first = alongs.first.first
    stop = profile.stops.select { |s| s.sequence < score.board.sequence && s.along <= first + DEPARTURE_STOP_M }
                  .max_by(&:sequence)
    return unless stop && first - stop.along <= DEPARTURE_STOP_M

    near = before.select do |p|
      p.ts <= fast_at && Gtfs::Matching::Geo.haversine(p.lon, p.lat, stop.lon, stop.lat) <= Gtfs::Config::BOARD_RADIUS_M
    end
    board_ts = (near.max_by(&:ts) || run.first).ts
    extra = before.select { |p| p.ts >= board_ts }
    shifted = score.dup
    shifted.board = stop
    shifted.started_at = board_ts
    shifted.point_ids = extra.map(&:id) + Array(score.point_ids)
    shifted.distance_m = (score.alight.along - stop.along).round
    window = match.window
    longer = Gtfs::Matching::WindowDetector::Window.new(points: extra + window.points, kind: :moving,
                                                        pauses: [], board_from_gap: false,
                                                        truncated: window.truncated,
                                                        truncated_start: window.truncated_start,
                                                        truncated_end: window.truncated_end, sparse: window.sparse)
    match.dup.tap do |m|
      m.score = shifted
      m.window = longer
    end
  end

  # The time of the first fix that starts a vehicle-speed stretch: DEPARTURE_MIN_M or more
  # to a fix DEPARTURE_SPAN_SECS later, at DEPARTURE_MIN_KMH or more; the next fix (5 to 40 s
  # on) no nearer to the start and the one before it (5 s or more) as far from that fix: a
  # multipath jump comes back, whichever end it is. nil without one.
  def self.vehicle_stretch_at(points)
    dist = ->(a, b) { Gtfs::Matching::Geo.haversine(a.lon, a.lat, b.lon, b.lat) }
    points.each_with_index do |a, i|
      points[(i + 1)..].each_with_index do |b, k|
        dt = b.ts - a.ts
        next if dt < DEPARTURE_SPAN_SECS.min
        break if dt > DEPARTURE_SPAN_SECS.max

        m = dist.call(a, b)
        next unless m >= DEPARTURE_MIN_M && m / dt * 3.6 >= DEPARTURE_MIN_KMH

        after = points[(i + k + 2)..].find { |c| c.ts >= b.ts + 5 }
        next unless after && after.ts <= b.ts + 40 && dist.call(a, after) >= m

        prior = points[0...i].reverse.find { |c| c.ts <= a.ts - 5 } # a itself no jump either
        return a.ts if prior.nil? || dist.call(prior, b) >= m
      end
    end
    nil
  end

  def vehicle_stretch_at(points) = self.class.vehicle_stretch_at(points)

  # 2026-11-22 (toth.bator, GPS logger): 133E to Keleti, then the M4 to Kelenföld underground,
  # then waiting for the S30. No fix from 13:28:53 (Keleti) to 13:52:39 (Kelenföld, the S30
  # leaving), so the gap held a 13 min ride and 10 min on the platform; scored as a slow ride the
  # M4 got 0.46 and was dropped. An unmatched gap that ends where the next ride boards (within
  # GAP_NEIGHBOUR_SECS and TRANSFER_RADIUS_M of its stop) is scored again with up to
  # TRANSFER_WAIT_SECS of waiting at its end; a metro or train ride found that way is added.
  def gaps_before_transfers(matches, stats)
    added = Array(@windows).select(&:gap?).filter_map do |gap|
      next if matches.any? { |m| m.started_at.to_i < gap.end_ts && m.ended_at.to_i > gap.start_ts }

      nxt = matches.select { |m| (m.started_at.to_i - gap.end_ts).between?(-GAP_NEIGHBOUR_SECS, GAP_NEIGHBOUR_SECS) }
                   .min_by { |m| m.started_at.to_i }
      next unless nxt && (stop = nxt.score.board)

      last = gap.points.last
      next if Gtfs::Matching::Geo.haversine(last.lon, last.lat, stop.lon, stop.lat) > TRANSFER_RADIUS_M

      waiting = gap.dup.tap { |w| w.wait_at_end = TRANSFER_WAIT_SECS }
      best, alternatives = evaluate(waiting, stats)
      best, alternatives = metro_over_rail(best, alternatives)
      next unless best && best.confidence >= drop_below(best) && %w[metro rail].include?(mode_of(best))

      stats['transfer_gaps'] += 1
      build_match(waiting, best, alternatives)
    end
    added.empty? ? matches : drop_overlaps(matches + added)
  end

  # With the wait the end of the gap no longer pins the arrival, so the timing cannot tell a
  # train from the metro (2026-11-22: rjx 66 0.60, M4 0.58). A train runs above ground, where
  # the logger keeps its fix; a gap without any fix between two stations is the metro, so a
  # metro trip within TRANSFER_GAP_METRO_SHARE of the best train is taken.
  def metro_over_rail(best, alternatives)
    return [best, alternatives] unless best && mode_of(best) == 'rail'

    metro = alternatives.find { |s| mode_of(s) == 'metro' && s.confidence >= best.confidence * TRANSFER_GAP_METRO_SHARE }
    metro ? [metro, [best] + (alternatives - [metro])] : [best, alternatives]
  end

  # Where the late-arrival lookahead must stop (review 2026-11-15: it could step over a GPS gap
  # and on into later rides). It may reach into the next movement window, which is often the
  # same train after the gap (2026-10-15, ride 21: stopping at its start brought the cut Z30 back),
  # but not past that window's end. A gap window is not a stop: stepping over it is the point.
  def next_movement_start(window)
    nxt = Array(@windows).select { |w| !w.gap? && w.start_ts > window.end_ts }.min_by(&:start_ts)
    nxt && (nxt.end_ts + 1)
  end

  # => growing lists of the points right after the window; a new list only when
  # the last point moved ARRIVAL_LOOKAHEAD_STEP_M from the previous try.
  def arrival_tries(window, stop_ts: nil)
    following = following_points(window.end_ts, stop_ts)
    anchor = window.points.last
    tries = []
    following.each_with_index do |point, index|
      next if Gtfs::Matching::Geo.haversine(anchor.lon, anchor.lat, point.lon, point.lat) < ARRIVAL_LOOKAHEAD_STEP_M

      tries << following[0..index]
      anchor = point
      break if tries.size >= ARRIVAL_LOOKAHEAD_TRIES
    end
    tries
  end

  # The points of the ARRIVAL_LOOKAHEAD_SECS after end_ts (before stop_ts). One
  # GPS gap up to ARRIVAL_MAX_GAP_SECS is stepped over and does not count.
  def following_points(end_ts, stop_ts)
    start = @stream.bsearch_index { |p| p.ts > end_ts }
    return [] unless start

    out = []
    budget = ARRIVAL_LOOKAHEAD_SECS
    gap_used = false
    prev = end_ts
    @stream[start..].each do |point|
      break if stop_ts && point.ts >= stop_ts

      dt = point.ts - prev
      if dt > ARRIVAL_LOOKAHEAD_SECS
        break if gap_used || dt > ARRIVAL_MAX_GAP_SECS

        gap_used = true
      else
        budget -= dt
        break if budget.negative?
      end
      out << point
      prev = point.ts
    end
    out
  end

  # The halves of a window (split at its longest pause) replace an uncertain
  # whole-window match only when they are two different rides (a transfer)
  # that fit better on average.
  def use_halves?(halves, best)
    return halves.any? if best.nil?

    trips = halves.map { |m| [m.score.candidate.feed.id, m.score.candidate.trip_gtfs_id] }.uniq
    trips.size >= 2 && (halves.sum(&:confidence) / halves.size) > best.confidence
  end

  def split_matches(window, depth, stats)
    window.split.select { |half| Gtfs::Matching::WindowDetector.long_enough?(half) }
          .flat_map { |half| match_window(half, depth + 1, stats) }
  end

  # => [best_score, other_scores]; grown_delay: see Gtfs::Config::GROWN_DELAY_MAX_SECS
  def evaluate(window, stats, grown_delay: false)
    board_points = endpoint_points(window.points)
    alight_points = endpoint_points(window.points.reverse)
    scores = []
    @feed_set.feeds.each do |feed|
      service_dates(window, feed).each do |date|
        version = @feed_set.version_for(feed, date)
        if version.nil?
          stats['no_timetable'] += 1
          next
        end

        finder = Gtfs::Matching::CandidateFinder.new(feed:, version:, service_date: date,
                                                     privacy_zones: @privacy_zones)
        next if window.slow? && !slow_window_plausible?(window, finder, board_points, alight_points)

        candidates = finder.call(window, board_points:, alight_points:, grown_delay:)
        stats['candidates'] += candidates.size
        candidates.each do |candidate|
          profile = Gtfs::Matching::TripProfile.load(feed, version, candidate.trip_gtfs_id, cache: @profiles)
          scores << Gtfs::Matching::Scorer.new(window, candidate, profile, grown_delay:).call
        end
      end
    end
    # ranked before the scorer's caps (e.g. no intermediate stop), which only
    # say how sure the best one is, not which one is best
    valid = prefer_metro_in_gaps(scores.reject(&:rejected))
            .sort_by { |s| [-s.raw_confidence, s.delay_secs.to_i.abs] }
    [valid.first, valid.drop(1)]
  end

  # A GPS gap with both ends at the stations of a metro trip that fits it is
  # most likely that metro: trains run at street level, where the phone keeps
  # its fix. Heavy-rail trips scored on the same gap are multiplied by
  # GAP_RAIL_NEAR_METRO_FACTOR (a train ride with points is not a gap ride
  # and is not touched).
  def prefer_metro_in_gaps(scores)
    metro = scores.any? do |s|
      s.gap_mode && mode_of(s) == 'metro' && s.features[:stops].to_f >= Gtfs::Config::GAP_METRO_MIN_STOPS
    end
    return scores unless metro

    factor = Gtfs::Config::GAP_RAIL_NEAR_METRO_FACTOR
    scores.map do |s|
      next s unless s.gap_mode && mode_of(s) == 'rail'

      s.dup.tap do |demoted|
        demoted.confidence = (s.confidence * factor).round(3)
        demoted.raw_confidence = (s.raw_confidence * factor).round(3)
      end
    end
  end

  def mode_of(score)
    TransitSegment.mode_for(score.profile.route&.route_type)
  end

  # Slow windows (avg < MIN_VEHICLE_SPEED) only count when both ends are near
  # stops and part of the window is clearly faster than walking (9.2).
  def slow_window_plausible?(window, finder, board_points, alight_points)
    window.p80_speed_kmh >= Gtfs::Config::SLOW_WINDOW_P80_KMH &&
      finder.stops_near(board_points).any? && finder.stops_near(alight_points).any?
  end

  # 9.3: the local date of the window start and the day before (times > 24:00)
  def service_dates(window, feed)
    date = Time.zone.at(window.start_ts).in_time_zone(feed.time_zone).to_date
    [date, date - 1]
  end

  def endpoint_points(points)
    first = points.first
    points.take_while { |p| (p.ts - first.ts).abs <= Gtfs::Config::ENDPOINT_SECS }
          .first(Gtfs::Config::ENDPOINT_POINTS)
  end

  def drop_below(score)
    if score.distance_m < Gtfs::Config::SHORT_SEGMENT_DISTANCE
      [Gtfs::Config::SHORT_SEGMENT_DROP_BELOW, Gtfs::Config::DROP_BELOW].max
    else
      Gtfs::Config::DROP_BELOW
    end
  end

  # 9.9: a different line within AMBIGUITY_MARGIN makes the match uncertain
  # (`ambiguous`). Another departure of the same line within the margin
  # (review K6) means the line is right but the trip, and so the delay, may
  # not be: `trip_ambiguous`. The same departure in an overlapping feed is
  # no alternative at all.
  def build_match(window, best, alternatives)
    label = line_label(best)
    within = ->(s) { best.raw_confidence - s.raw_confidence < Gtfs::Config::AMBIGUITY_MARGIN }
    close = ->(s) { within.call(s) && !delay_tiebreak?(best, s) }
    # the tie-break picks the trip, but the GPS could not tell them apart:
    # the ride stays uncertain (review K2)
    rivals, same_line = alternatives.partition { |s| line_label(s) != label }
    # only a different line decided by the delay caps; another departure of
    # the same line keeps the line right (trip_ambiguous logic, review K6)
    best = tiebreak_capped(best) if rivals.any? { |s| within.call(s) && delay_tiebreak?(best, s) }
    other_trips = same_line.reject { |s| departure_of(s) == departure_of(best) }
    Match.new(score: best, alternatives: rivals.first(3), ambiguous: rivals.any?(&close),
              trip_alternatives: other_trips.select(&close).first(3), trip_ambiguous: other_trips.any?(&close),
              window_kind: window.kind, window:)
  end

  # Review 10-16 (9057 vs IC 849): two trips on the same track, same stops,
  # within the margin, are decided by the delay when the best one's |delay|
  # is at least AMBIGUITY_DELAY_TIEBREAK_SECS smaller: the shape and stop
  # features are identical, so the delay is the only real difference.
  def delay_tiebreak?(best, other)
    return false if best.delay_secs.nil? || other.delay_secs.nil?
    return false unless same_stop?(best.board, other.board) && same_stop?(best.alight, other.alight)
    # gap mode has no shape: the track cannot be compared, no tie-break
    return false if best.features[:shape].nil?
    return false unless %i[shape stops].all? { |k| best.features[k] == other.features[k] }

    other.delay_secs.abs - best.delay_secs.abs >= Gtfs::Config::AMBIGUITY_DELAY_TIEBREAK_SECS
  end

  # Same stop: the same stop_id, or the same parent station (other platform)
  def same_stop?(a, b)
    return false if a.nil? || b.nil?
    return true if a.stop_gtfs_id.present? && a.stop_gtfs_id == b.stop_gtfs_id

    a.parent_station_gtfs_id.present? && a.parent_station_gtfs_id == b.parent_station_gtfs_id
  end

  def tiebreak_capped(score)
    cap = Gtfs::Config::AUTO_ACCEPT - 0.01
    score.dup.tap do |capped|
      capped.confidence = [score.confidence, cap].min.round(3)
      capped.caps = (Array(score.caps) + ['delay_tiebreak']).uniq
    end
  end

  # A train standing longer than PAUSE_MAX_SECS at a station (a scheduled
  # dwell, a crossing, GPS lost under the station roof) splits the movement
  # into two windows, and both halves match the same trip. Such neighbours
  # are joined: the points from the start of the first to the end of the
  # second form one window that is scored again (board, alight, confidence
  # and features of the whole ride). The join is kept only when that score
  # still picks the same trip.
  def merge_same_trip(matches, points, windows, stats)
    matches.each_with_object([]) do |match, merged|
      previous = merged.last
      joined = previous && continuation?(previous, match, windows) && join(previous, match, points, stats)
      if joined
        merged[-1] = joined
        stats['merged_rides'] += 1
      else
        merged << match
      end
    end
  end

  # Same feed, version, service day and trip; the second ride boards where
  # the first alighted or at the next call; the time between them fits the
  # timetable (+ MERGE_GAP_SLACK_SECS); and no other movement window (a walk,
  # an unmatched ride, a metro gap) lies between them.
  def continuation?(first, second, windows)
    a = first.score
    b = second.score
    return false unless first.window && second.window && same_trip?(a, b)
    return false if b.board.sequence < a.alight.sequence
    return false if a.profile.stops.any? { |c| c.sequence > a.alight.sequence && c.sequence < b.board.sequence }

    scheduled = b.board.departure_secs - a.alight.arrival_secs
    return false if b.started_at - a.ended_at > scheduled + Gtfs::Config::MERGE_GAP_SLACK_SECS

    windows.none? { |w| w.start_ts > first.window.end_ts && w.end_ts < second.window.start_ts }
  end

  # A train standing at a station or a run of rough fixes can split a ride
  # into two movement windows, and the second, too short to match on its
  # own, was lost: the ride ended at the split (ride 145, 2026-10-23: G44
  # Kelenföld -> Dinnyés, 21 s before the last 11 km to Székesfehérvár;
  # Bator). A movement window that starts at most EXTEND_GAP_SECS after a
  # ride and that no other ride covers is scored together with it; the
  # longer ride is kept when it is accepted on the same trip (or rides_on?).
  def extend_into_next(matches, points, windows, stats)
    matches.map do |match|
      EXTEND_MAX_STEPS.times do
        longer = extend_once(match, matches, points, windows, stats)
        break unless longer

        match = longer
      end
      match
    end
  end

  def extend_once(match, matches, points, windows, stats)
    return unless match.window

    last = match.window.end_ts
    nxt = windows.find { |w| !w.gap? && w.start_ts >= last && w.start_ts - last <= EXTEND_GAP_SECS }
    return unless nxt
    return if matches.any? { |m| !m.equal?(match) && m.started_at < nxt.end_ts && m.ended_at > nxt.start_ts }

    window = Gtfs::Matching::WindowDetector::Window.new(
      points: points.select { |p| p.ts.between?(match.window.start_ts, nxt.end_ts) }, kind: :moving, pauses: [],
      board_from_gap: match.window.board_from_gap, truncated: match.window.truncated_start || nxt.truncated_end,
      truncated_start: match.window.truncated_start, truncated_end: nxt.truncated_end,
      sparse: [match.window, nxt].any?(&:sparse)
    )
    best, alternatives = evaluate(window, stats, grown_delay: true)
    return unless best && best.confidence >= drop_below(best)
    return unless same_trip?(best, match.score) || rides_on?(best, match)

    stats['extended_rides'] += 1
    build_match(window, best, alternatives)
  end

  # 2026-11-25 (phone): the short stretch from the Székesfehérvár bus station to Jancsár utca
  # fitted city bus 10 best, the whole ride to Úrhida only the 8069 (Volán), which serves the
  # same stops. Another trip may take over the extended ride when it boards at the same place,
  # alights later and scores at least as well as the short ride.
  def rides_on?(best, match)
    a = best.board
    b = match.score.board
    return false if a.nil? || b.nil? || best.ended_at.to_i <= match.ended_at.to_i
    return false if best.confidence < match.confidence

    same_stop?(a, b) || Gtfs::Matching::Geo.haversine(a.lon, a.lat, b.lon, b.lat) <= Gtfs::Config::GAP_JOIN_STOP_RADIUS_M
  end

  def same_trip?(score, other)
    ca = score.candidate
    cb = other.candidate
    ca.feed.id == cb.feed.id && ca.version == cb.version && ca.service_date == cb.service_date &&
      ca.trip_gtfs_id == cb.trip_gtfs_id
  end

  def join(first, second, points, stats)
    from = first.window.start_ts
    to = second.window.end_ts
    window = Gtfs::Matching::WindowDetector::Window.new(points: points.select { |p| p.ts.between?(from, to) },
                                                        kind: :moving, pauses: [])
    best, alternatives = evaluate(window, stats)
    return unless best && same_trip?(best, first.score) && best.confidence >= drop_below(best)

    build_match(window, best, alternatives)
  end

  def departure_of(score)
    [score.candidate.service_date, score.board.departure_secs]
  end

  def line_label(score)
    [score.profile.line_name, score.profile.route&.route_type]
  end

  def drop_overlaps(matches)
    kept = []
    matches.sort_by { |m| -m.confidence }.each do |match|
      overlapping = kept.any? do |other|
        [match.ended_at, other.ended_at].min - [match.started_at, other.started_at].max > OVERLAP_SECS
      end
      kept << match unless overlapping
    end
    kept.sort_by(&:started_at)
  end
end
