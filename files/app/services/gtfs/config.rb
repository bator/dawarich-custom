# frozen_string_literal: true

# Tunable parameters of the GTFS segment matcher (spec 9.2-9.6, 13). Every
# value can be overridden with the environment variable of the same name
# (GTFS_...); the defaults are the starting values of the spec.
module Gtfs::Config
  def self.float(name, default)
    ENV.fetch(name, default).to_f
  end

  def self.int(name, default)
    ENV.fetch(name, default).to_i
  end

  # 9.1 input cleaning
  MAX_ACCURACY_M          = int('GTFS_MATCH_MAX_ACCURACY_M', 100)
  MAX_JUMP_SPEED_KMH      = float('GTFS_MATCH_MAX_JUMP_SPEED_KMH', 400)

  # 9.2 movement windows
  MIN_SEGMENT_DURATION    = int('GTFS_MATCH_MIN_SEGMENT_DURATION', 120)   # seconds
  MIN_SEGMENT_DISTANCE    = int('GTFS_MATCH_MIN_SEGMENT_DISTANCE', 400)   # metres
  MIN_VEHICLE_SPEED_KMH   = float('GTFS_MATCH_MIN_VEHICLE_SPEED_KMH', 12)
  # A window slower than MIN_VEHICLE_SPEED still counts when it starts and
  # ends near stops, but only if it has a sustained part faster than walking.
  SLOW_WINDOW_P80_KMH     = float('GTFS_MATCH_SLOW_WINDOW_P80_KMH', 15)
  MOVING_SPEED_KMH        = float('GTFS_MATCH_MOVING_SPEED_KMH', 8)       # smoothed speed of a "moving" point
  SPEED_SMOOTHING_SECS    = int('GTFS_MATCH_SPEED_SMOOTHING_SECS', 30)    # +/- around each point
  PAUSE_MAX_SECS          = int('GTFS_MATCH_PAUSE_MAX_SECS', 180)         # dwell at a stop / traffic light
  PAUSE_MAX_DISTANCE      = int('GTFS_MATCH_PAUSE_MAX_DISTANCE', 300)     # metres moved during such a pause
  GAP_SECS                = int('GTFS_MATCH_GAP_SECS', 600)               # 9.2/9.6 GPS outage
  MAX_GAP_SECS            = int('GTFS_MATCH_MAX_GAP_SECS', 3 * 3600)
  SPLIT_DEPTH             = int('GTFS_MATCH_SPLIT_DEPTH', 2)              # retry halves at pauses (transfers)
  # Two rides on the same trip are joined when the time between them is at
  # most the scheduled time between the two calls plus this (GPS lost at a
  # station, a train waiting longer than planned).
  MERGE_GAP_SLACK_SECS    = int('GTFS_MATCH_MERGE_GAP_SLACK_SECS', 600)

  # 9.3 candidate search
  BOARD_RADIUS_M          = int('GTFS_BOARD_RADIUS_M', 120)
  # Railway stations are one point in the feed but the platforms are a few
  # hundred metres long: stops served by rail routes use this radius.
  RAIL_BOARD_RADIUS_M     = int('GTFS_RAIL_BOARD_RADIUS_M', 300)
  RAIL_ROUTE_TYPES        = [2, *100..117].freeze
  TIME_TOLERANCE_SECS     = int('GTFS_TIME_TOLERANCE_SECS', 900)
  ENDPOINT_POINTS         = int('GTFS_MATCH_ENDPOINT_POINTS', 3)          # "first/last points" of a window
  ENDPOINT_SECS           = int('GTFS_MATCH_ENDPOINT_SECS', 90)
  MAX_CANDIDATES          = int('GTFS_MATCH_MAX_CANDIDATES', 15)          # scored in detail (9.5: "best 10")

  # 9.4 scoring
  WEIGHTS = {
    shape: float('GTFS_MATCH_WEIGHT_SHAPE', 0.40),
    time: float('GTFS_MATCH_WEIGHT_TIME', 0.25),
    stops: float('GTFS_MATCH_WEIGHT_STOPS', 0.15),
    direction: float('GTFS_MATCH_WEIGHT_DIRECTION', 0.10),
    coverage: float('GTFS_MATCH_WEIGHT_COVERAGE', 0.10),
    fixes: float('GTFS_MATCH_WEIGHT_FIXES', 0.40) # underground metro: the few fixes inside a gap
  }.freeze
  SHAPE_MAX_DISTANCE_M    = float('GTFS_MATCH_SHAPE_MAX_DISTANCE_M', 80)
  # Trips without a usable shape (most MAV trains): the straight lines between
  # stops can be kilometres from the track, so the path and the schedule are
  # checked at the stops instead (see Scorer, "stop mode").
  STOP_PASS_RADIUS_M      = float('GTFS_MATCH_STOP_PASS_RADIUS_M', 300)
  STOP_SLOW_SPEED_MS      = float('GTFS_MATCH_STOP_SLOW_SPEED_MS', 3) # "standing" at a stop
  STOP_MODE_MAX_CROSS_M   = float('GTFS_MATCH_STOP_MODE_MAX_CROSS_M', 1500) # off the line between the stops
  STOP_MODE_CROSS_SHARE   = float('GTFS_MATCH_STOP_MODE_CROSS_SHARE', 0.2) # ... or this share of the leg
  OFF_LINE_SHARE          = float('GTFS_MATCH_OFF_LINE_SHARE', 0.3)
  EARLY_DEPARTURE_SLACK   = int('GTFS_MATCH_EARLY_DEPARTURE_SLACK', 60) # schedule rounding
  EARLY_DEPARTURE_REJECT_SECS = int('GTFS_MATCH_EARLY_DEPARTURE_REJECT_SECS', 150) # stop mode: not that train
  EARLY_ARRIVAL_SLACK     = int('GTFS_MATCH_EARLY_ARRIVAL_SLACK', 300)    # timetable padding before a station
  DELAY_RECOVERY_SLACK    = int('GTFS_MATCH_DELAY_RECOVERY_SLACK', 120)   # a delay shrinks only a little
  TIME_ERROR_MAX_SECS     = float('GTFS_MATCH_TIME_ERROR_MAX_SECS', 120)
  OFFSET_STEP_SECS        = int('GTFS_MATCH_OFFSET_STEP_SECS', 30)
  DELAY_PENALTY           = float('GTFS_MATCH_DELAY_PENALTY', 0.2)        # early, at |delay| = TIME_TOLERANCE
  LATE_DELAY_PENALTY      = float('GTFS_MATCH_LATE_DELAY_PENALTY', 0.1)   # late (review K6)
  COVERAGE_GAP_SECS       = int('GTFS_MATCH_COVERAGE_GAP_SECS', 120)
  DIRECTION_SLACK_M       = float('GTFS_MATCH_DIRECTION_SLACK_M', 25)
  # Gates: a candidate whose schedule or path clearly does not fit is never
  # accepted, however well the other features score (14.3 false positive).
  MIN_TIME_SCORE          = float('GTFS_MATCH_MIN_TIME_SCORE', 0.35)
  # Railway trips with a shape are timed at the stops (Scorer#rail_timing?).
  RAIL_STOP_TIMING        = ENV.fetch('GTFS_MATCH_RAIL_STOP_TIMING', 'true') != 'false'
  MIN_SHAPE_SCORE         = float('GTFS_MATCH_MIN_SHAPE_SCORE', 0.25)
  # Dwell check for road vehicles (review K2): bus 3/700-799, tram 0/900-906,
  # trolleybus 11/800, cable tram 5.
  DWELL_ROUTE_TYPES       = [0, 3, 5, 11, *700..799, 800, *900..906].freeze
  DWELL_RADIUS_M          = float('GTFS_MATCH_DWELL_RADIUS_M', 50)
  DWELL_MIN_CALLS         = int('GTFS_MATCH_DWELL_MIN_CALLS', 2)
  DWELL_MAX_SAMPLE_SECS   = int('GTFS_MATCH_DWELL_MAX_SAMPLE_SECS', 15) # only dense tracks show a dwell
  MIN_DWELL_SHARE         = float('GTFS_MATCH_MIN_DWELL_SHARE', 0.34)

  AUTO_ACCEPT             = float('GTFS_MATCH_AUTO_ACCEPT', 0.75)
  DROP_BELOW              = float('GTFS_MATCH_DROP_BELOW', 0.50)
  MIN_CONFIDENCE          = [float('GTFS_MATCH_MIN_CONFIDENCE', 0.6), DROP_BELOW].max
  AMBIGUITY_MARGIN        = float('GTFS_MATCH_AMBIGUITY_MARGIN', 0.05)
  # ... unless both trips have the same shape and stop features and the best
  # one's |delay| is at least this much smaller (SegmentMatcher#delay_tiebreak?)
  AMBIGUITY_DELAY_TIEBREAK_SECS = int('GTFS_MATCH_AMBIGUITY_DELAY_TIEBREAK_SECS', 180)
  # 17.12: rides shorter than this need a higher score
  SHORT_SEGMENT_DISTANCE  = int('GTFS_MATCH_SHORT_SEGMENT_DISTANCE', 1000)
  SHORT_SEGMENT_DROP_BELOW = float('GTFS_MATCH_SHORT_SEGMENT_DROP_BELOW', 0.6)

  # Sparse / low-coverage tracks (10-15 rides 17 and 18). A ride whose points
  # cover less than MIN_CERTAIN_COVERAGE of its time, or that has fewer than
  # one point per SECS_PER_POINT_CERTAIN or fewer than MIN_CERTAIN_POINTS
  # points, is capped below AUTO_ACCEPT (uncertain). Coverage is proportional
  # (a step counts up to the coverage gap limit), so only a ride with
  # practically no points falls below REJECT_COVERAGE and is rejected.
  # Gap-mode rides (underground) are exempt: no points is what they look like.
  MIN_CERTAIN_COVERAGE    = float('GTFS_MATCH_MIN_CERTAIN_COVERAGE', 0.3)
  REJECT_COVERAGE         = float('GTFS_MATCH_REJECT_COVERAGE', 0.05)
  SECS_PER_POINT_CERTAIN  = int('GTFS_MATCH_SECS_PER_POINT_CERTAIN', 180)
  MIN_CERTAIN_POINTS      = int('GTFS_MATCH_MIN_CERTAIN_POINTS', 8)
  # Sparse mode: the local median spacing of the points is above this. The
  # stream is then split only at gaps longer than SPARSE_GAP_SECS (intended
  # range 900..1200 s; an env value outside it is kept but warned about) and
  # coverage counts steps up to SPARSE_COVERAGE_GAP_SECS.
  SPARSE_MEDIAN_SPACING_SECS = int('GTFS_MATCH_SPARSE_MEDIAN_SPACING_SECS', 120)
  SPARSE_SPACING_NEIGHBOURS = int('GTFS_MATCH_SPARSE_SPACING_NEIGHBOURS', 5) # steps on each side of a gap
  SPARSE_GAP_SECS         = int('GTFS_MATCH_SPARSE_GAP_SECS', 1080)
  unless SPARSE_GAP_SECS.between?(900, 1200)
    message = "[GTFS config] GTFS_MATCH_SPARSE_GAP_SECS=#{SPARSE_GAP_SECS} is outside the intended 900..1200 s"
    defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger ? Rails.logger.warn(message) : warn(message)
  end
  SPARSE_COVERAGE_GAP_SECS = int('GTFS_MATCH_SPARSE_COVERAGE_GAP_SECS', 300)
  # A window that starts or ends within this many seconds of a point dropped
  # for low accuracy (MAX_ACCURACY_M) was probably cut short: capped uncertain.
  TRUNCATION_SECS         = int('GTFS_MATCH_TRUNCATION_SECS', 300)
  # ... unless the ride is dense, covers at least this share and its shape
  # score is at least this (real shape, not stop mode): no cap then.
  TRUNCATED_EXEMPT_MIN_COVERAGE = float('GTFS_MATCH_TRUNCATED_EXEMPT_MIN_COVERAGE', 0.9)
  TRUNCATED_EXEMPT_MIN_SHAPE = float('GTFS_MATCH_TRUNCATED_EXEMPT_MIN_SHAPE', 0.9)
  # Adjacent moving windows of a sparse track separated by at most this many
  # seconds are one ride (user 1, 10-15 16:37:25 / 16:37:43).
  SPARSE_JOIN_GAP_SECS    = int('GTFS_MATCH_SPARSE_JOIN_GAP_SECS', 180)
  # Rail departure: a step away from the boarding stop, forward along the
  # trip, at least this fast confirms the movement (not platform walking);
  # the departure time is the start of that movement (Scorer#movement_start).
  RAIL_DEPARTURE_MIN_KMH  = float('GTFS_MATCH_RAIL_DEPARTURE_MIN_KMH', 15)
  # Rail departure trace-back (Scorer#movement_start): a step farther from
  # the stop than GPS jitter, a fix this slow is the train standing, and
  # only steps this short show the acceleration (dense track).
  MOVEMENT_MIN_STEP_M     = float('GTFS_MATCH_MOVEMENT_MIN_STEP_M', 0.5)
  MOVEMENT_STILL_SPEED_MS = float('GTFS_MATCH_MOVEMENT_STILL_SPEED_MS', 0.3)
  MOVEMENT_MAX_STEP_SECS  = int('GTFS_MATCH_MOVEMENT_MAX_STEP_SECS', 30)
  # A gap window is joined with a neighbouring movement window (SegmentMatcher)
  # only for metro trips or when the gap's outer end lies within this
  # distance of the boarding/alighting stop (default: the rail radius).
  GAP_JOIN_STOP_RADIUS_M  = int('GTFS_MATCH_GAP_JOIN_STOP_RADIUS_M', 300)

  # 9.6 gaps (underground)
  GAP_MODE_MIN_SECS       = int('GTFS_MATCH_GAP_MODE_MIN_SECS', 180)
  GAP_DURATION_TOLERANCE  = float('GTFS_MATCH_GAP_DURATION_TOLERANCE', 0.25)
  GAP_ACCESS_SLACK_SECS   = int('GTFS_MATCH_GAP_ACCESS_SLACK_SECS', 240) # walking to/from the platform
  GAP_FACTOR              = float('GTFS_MATCH_GAP_FACTOR', 0.85)
  # Underground metro (gap mode on a metro trip): walking down, waiting on the
  # platform and walking up again take longer than for a train at street level
  METRO_ACCESS_SLACK_SECS = int('GTFS_MATCH_METRO_ACCESS_SLACK_SECS', 480)
  # a metro ride whose points cover less than this share is scored like a gap
  METRO_SPARSE_COVERAGE   = float('GTFS_MATCH_METRO_SPARSE_COVERAGE', 0.5)
  # rough fixes inside the gap: an accuracy below this counts as this
  METRO_FIX_MIN_ACCURACY_M = float('GTFS_MATCH_METRO_FIX_MIN_ACCURACY_M', 25)
  # sum of fix weights (MIN_ACCURACY / accuracy) that counts as full evidence
  METRO_FIX_FULL_WEIGHT = float('GTFS_MATCH_METRO_FIX_FULL_WEIGHT', 2.0)
  # gap rides: a heavy-rail trip is multiplied by this when a metro trip fits
  # the same gap with both ends at its stations (stops feature >= GAP_METRO_MIN_STOPS)
  GAP_RAIL_NEAR_METRO_FACTOR = float('GTFS_MATCH_GAP_RAIL_NEAR_METRO_FACTOR', 0.85)
  GAP_METRO_MIN_STOPS     = float('GTFS_MATCH_GAP_METRO_MIN_STOPS', 0.5)

  # Jobs (decision K4: only the active and one backup timetable exist)
  MATCH_LOOKBACK_DAYS     = int('GTFS_MATCH_LOOKBACK_DAYS', 2)
  REMATCH_DAYS            = int('GTFS_REMATCH_DAYS', 7)
  DAY_BUFFER_SECS         = 2 * 3600
end
