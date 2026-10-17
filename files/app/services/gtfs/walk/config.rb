# frozen_string_literal: true

require 'ipaddr'
require 'uri'

# Walking stretches next to transit rides (walk to the stop, transfers) snapped
# to footpaths with Valhalla (pedestrian, map_snap), either through Dawarich
# Atlas (POST /api/v1/map-match, preferred) or a raw Valhalla
# (/trace_attributes). Off by default; see docs/gtfs-walk.md. Every value can
# be overridden with the environment variable of the same name.
module Gtfs::Walk::Config
  TRUE_VALUES = %w[1 true yes on].freeze
  APIS = %w[atlas valhalla].freeze
  SCOPES = %w[transit all].freeze

  def self.flag(name, default)
    TRUE_VALUES.include?(ENV.fetch(name, default.to_s).to_s.strip.downcase)
  end

  # Unparsable or out-of-range values fall back to the default (review A-3:
  # "abc" must not become a 0 s timeout).
  def self.float(name, default, min: 0.0, max: Float::INFINITY)
    value = Float(ENV.fetch(name, ''), exception: false)
    value && value >= min && value <= max ? value : default.to_f
  end

  def self.int(name, default, min: 0, max: 2**31)
    value = Integer(ENV.fetch(name, ''), 10, exception: false)
    value && value >= min && value <= max ? value : default
  end

  # Feature flag (default OFF). Without it Gtfs::MatchDay never calls Valhalla.
  def self.enabled? = flag('GTFS_WALK_SNAP_ENABLED', false)

  # Dry run: legs are computed and logged, nothing is written (also when the
  # flag is on). The rake task gtfs:walk_snap is always dry unless WRITE=1.
  def self.dry_run? = flag('GTFS_WALK_SNAP_DRY_RUN', false)

  # Base URL of Atlas (http://host:8484) or of a raw Valhalla
  # (http://host:8002). No default (review K2): unset = walk snapping is off.
  def self.valhalla_url
    url = ENV.fetch('GTFS_WALK_VALHALLA_URL', '').to_s.strip.chomp('/')
    url.empty? ? nil : url
  end

  # `atlas` (POST /api/v1/map-match, health: GET /api/v1/coverage) or
  # `valhalla` (POST /trace_attributes, health: GET /status).
  def self.api
    value = ENV.fetch('GTFS_WALK_VALHALLA_API', 'atlas').to_s.strip.downcase
    APIS.include?(value) ? value : nil
  end

  # Extra host names allowed besides private (RFC 1918, fc00::/7) and loopback
  # IP literals (not link-local 169.254/16, fe80::/10: review N7), comma
  # separated. GPS traces must never go to a random host because of a wrong
  # variable (review K2).
  def self.allowed_hosts
    ENV.fetch('GTFS_WALK_VALHALLA_ALLOWED_HOSTS', '').split(',').map { |h| h.strip.downcase }.reject(&:empty?)
  end

  # => nil when the URL can be used, else the reason (logged, nothing is sent)
  def self.url_problem(url = valhalla_url)
    return 'GTFS_WALK_VALHALLA_URL is not set' if url.nil?
    return "GTFS_WALK_VALHALLA_API must be one of #{APIS.join('/')}" if api.nil?

    uri = URI.parse(url)
    return "unsupported URL #{url}" unless %w[http https].include?(uri.scheme) && uri.host.present?
    return nil if allowed_hosts.include?(uri.host.downcase)

    ip = IPAddr.new(uri.host.delete('[]'))
    ip.private? || ip.loopback? ? nil : "#{uri.host} is not a private address"
  rescue URI::InvalidURIError, IPAddr::InvalidAddressError
    "#{url} is not a private IP address and not in GTFS_WALK_VALHALLA_ALLOWED_HOSTS"
  end

  # Excluded accounts, comma separated, plus users whose settings contain
  # gtfs_walk_opt_out: true. No address lives in the code (review A-2); the
  # variable must list at least one entry ("-" when nobody is excluded) or
  # walk snapping stays off and nothing is shown (review K1), so a
  # deployment cannot lose its exclusions by forgetting it. An empty or
  # blank value (e.g. `GTFS_WALK_SNAP_EXCLUDE_EMAILS=` left in an env file)
  # counts as not set.
  def self.exclude_list_set? = excluded_emails.any?

  def self.excluded_emails
    ENV.fetch('GTFS_WALK_SNAP_EXCLUDE_EMAILS', '').split(',').map { |e| e.strip.downcase }.reject(&:empty?).uniq
  end

  def self.excluded?(user)
    return true if excluded_emails.include?(user.email.to_s.strip.downcase)

    settings = user.respond_to?(:settings) ? user.settings : nil
    settings.is_a?(Hash) && TRUE_VALUES.include?(settings['gtfs_walk_opt_out'].to_s.downcase)
  end

  # `transit`: only walking legs that end at a ride's boarding or start at its
  # alighting (within ADJACENT_SECS) -- walk to the stop, transfers.
  # `all`: every walking leg of the day (evaluation only).
  def self.scope
    value = ENV.fetch('GTFS_WALK_SNAP_SCOPE', 'transit').to_s.strip
    SCOPES.include?(value) ? value : 'transit'
  end

  # Shadow dry run (docs/gtfs-walk.md): `all` = after the live snap of a day,
  # the legs scope `all` would add are snapped too and only logged as
  # `[GTFS walk shadow]`, never written. Anything else (default) = off.
  def self.shadow_scope
    ENV.fetch('GTFS_WALK_SNAP_SHADOW_SCOPE', '').to_s.strip.downcase == 'all' ? 'all' : nil
  end

  # HTTP (review K-1): a hanging server must not hold the user's match lock
  OPEN_TIMEOUT_SECS     = float('GTFS_WALK_VALHALLA_OPEN_TIMEOUT', 2, min: 0.1, max: 30)
  # longer than Atlas' VALHALLA_MATCH_TIMEOUT (deploy/valhalla/README.md: 6 s),
  # so Atlas answers 502 before we give up on a request (review N5)
  READ_TIMEOUT_SECS     = float('GTFS_WALK_VALHALLA_READ_TIMEOUT', 10, min: 0.5, max: 60)
  MAX_RESPONSE_BYTES    = int('GTFS_WALK_MAX_RESPONSE_BYTES', 5_000_000, min: 10_000)
  MAX_REQUEST_POINTS    = int('GTFS_WALK_MAX_REQUEST_POINTS', 1500, min: 10, max: 10_000)
  HEALTH_CACHE_SECS     = int('GTFS_WALK_HEALTH_CACHE_SECS', 600)
  # Circuit breaker and time budget per user-day (review M1)
  DAY_BUDGET_SECS       = float('GTFS_WALK_DAY_BUDGET_SECS', 60, min: 1)
  # ... and the shadow dry run's own share, spent after the live snap
  SHADOW_BUDGET_SECS    = float('GTFS_WALK_SHADOW_BUDGET_SECS', 30, min: 1)

  # Leg extraction
  ADJACENT_SECS         = int('GTFS_WALK_ADJACENT_SECS', 1200)
  MAX_WALK_P80_KMH      = float('GTFS_WALK_MAX_P80_KMH', 9) # faster = not walking (bike, car)
  MIN_LEG_DISTANCE_M    = float('GTFS_WALK_MIN_LEG_DISTANCE_M', 100)
  MIN_LEG_POINTS        = int('GTFS_WALK_MIN_LEG_POINTS', 5, min: 2)
  MAX_POINT_GAP_SECS    = int('GTFS_WALK_MAX_POINT_GAP_SECS', 300) # a longer GPS gap splits the leg
  MAX_POINT_GAP_M       = float('GTFS_WALK_MAX_POINT_GAP_M', 250) # ... and so does a longer jump
  # Recorded (raw/stationary) parts are cut where two fixes are farther apart:
  # nothing longer is drawn as a straight line (review M6)
  RAW_MAX_SEGMENT_M     = float('GTFS_WALK_RAW_MAX_SEGMENT_M', 60, min: 5)
  # A snapped line is cut (gap) at a straight segment longer than this. It is
  # only a last-resort net: the clients already split where Valhalla's answer
  # is not one path (review N1). A long straight segment of a snapped line lies
  # on a map edge and is normally right -- Budapest bridges have 335-610 m
  # segments (review U1) -- unlike RAW_MAX_SEGMENT_M, which is about the
  # unknown way between two recorded fixes.
  SNAP_MAX_SEGMENT_M    = float('GTFS_WALK_SNAP_MAX_SEGMENT_M', 1000, min: 50)

  # Stationary clouds (stops): never sent to Valhalla (it draws loops there)
  STATIONARY_RADIUS_M   = float('GTFS_WALK_STATIONARY_RADIUS_M', 30)
  STATIONARY_MIN_SECS   = int('GTFS_WALK_STATIONARY_MIN_SECS', 90)
  MIN_SPACING_M         = float('GTFS_WALK_MIN_SPACING_M', 5) # thinning of the request

  # Request-level trace_options (review K-3): search_radius from the median
  # reported accuracy (x RADIUS_FACTOR, RADIUS_MIN_M..RADIUS_MAX_M; Valhalla
  # rejects more than its configured maximum), gps_accuracy = median accuracy,
  # breakage_distance = MAX_POINT_GAP_M. Per-point `accuracy` is sent as well.
  RADIUS_FACTOR         = float('GTFS_WALK_RADIUS_FACTOR', 3, min: 1)
  RADIUS_MIN_M          = float('GTFS_WALK_RADIUS_MIN_M', 30, min: 1, max: 100)
  RADIUS_MAX_M          = float('GTFS_WALK_RADIUS_MAX_M', 100, min: 1, max: 100)
  DEFAULT_ACCURACY_M    = float('GTFS_WALK_DEFAULT_ACCURACY_M', 15, min: 1)
  # Raw Valhalla only (Atlas does not forward it); unset = Valhalla's default
  TURN_PENALTY_FACTOR   = float('GTFS_WALK_TURN_PENALTY_FACTOR', 0, max: 100_000)

  # Quality gates for one snapped run (same idea as the OSRM car snap:
  # length ratio, deviation, distance of the raw points to the line)
  DENSE_SPACING_M       = float('GTFS_WALK_DENSE_SPACING_M', 40)
  MIN_RATIO_DENSE       = float('GTFS_WALK_MIN_RATIO_DENSE', 0.6)
  MAX_RATIO_DENSE       = float('GTFS_WALK_MAX_RATIO_DENSE', 1.25)
  MIN_RATIO_SPARSE      = float('GTFS_WALK_MIN_RATIO_SPARSE', 0.85)
  MAX_RATIO_SPARSE      = float('GTFS_WALK_MAX_RATIO_SPARSE', 1.6)
  RATIO_MARGIN_M        = float('GTFS_WALK_RATIO_MARGIN_M', 40)
  MAX_MEDIAN_M          = float('GTFS_WALK_MAX_MEDIAN_M', 20)
  MAX_P95_M             = float('GTFS_WALK_MAX_P95_M', 50)
  STRAY_FAR_M           = float('GTFS_WALK_STRAY_FAR_M', 60)
  MAX_STRAY_FRACTION    = float('GTFS_WALK_MAX_STRAY_FRACTION', 0.1)
  MIN_RUN_POINTS        = int('GTFS_WALK_MIN_RUN_POINTS', 3, min: 2)
  WITHIN_M              = 25 # reported metric only (share of raw points within 25 m)

  VERSION = 2
end
