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
#   join consecutive rides on the same trip and score them again as one
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
  GAP_NEIGHBOUR_SECS = 60 # a gap window and a movement window this close share their edge point

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
    windows = Gtfs::Matching::WindowDetector.new(points, dropped_ts: loader.dropped_accuracy_ts).call
                                            .select { |w| w.start_ts >= from_ts && w.start_ts < to_ts }
    stats['points'] = points.count { |p| p.ts >= from_ts && p.ts < to_ts }
    stats['windows'] = windows.size

    matches = match_windows(windows, stats)
    matches = merge_same_trip(drop_overlaps(matches), points, windows, stats)
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
      first, second = windows[index, 2]
      if second && gap_neighbours?(first, second)
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
                           best.confidence >= separate.map(&:confidence).max

    stats['gap_joins'] += 1
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

    halves = depth < Gtfs::Config::SPLIT_DEPTH ? split_matches(window, depth, stats) : []
    if use_halves?(halves, accepted ? best : nil)
      stats['split_windows'] += 1
      return halves
    end
    accepted ? [build_match(window, best, alternatives)] : []
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

  # => [best_score, other_scores]
  def evaluate(window, stats)
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

        candidates = finder.call(window, board_points:, alight_points:)
        stats['candidates'] += candidates.size
        candidates.each do |candidate|
          profile = Gtfs::Matching::TripProfile.load(feed, version, candidate.trip_gtfs_id, cache: @profiles)
          scores << Gtfs::Matching::Scorer.new(window, candidate, profile).call
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
