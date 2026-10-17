# frozen_string_literal: true

# Snaps the walking legs of one user's day (see docs/gtfs-walk.md). Called by
# Gtfs::MatchDay after the rides are saved when GTFS_WALK_SNAP_ENABLED is set,
# and by `gtfs:walk_snap` (dry run by default); both hold the user's match lock.
#
# Reads points (the matcher's PointLoader, read-only) and calls Atlas or
# Valhalla. Writes only the derived table transit_walk_legs, and nothing at
# all in a dry run. The points table is never changed.
#
# Nothing is sent and nothing is written (skipped:) when
# - the account is excluded (its legs are removed instead, unless dry),
# - GTFS_WALK_SNAP_EXCLUDE_EMAILS is not set or empty, or the URL is missing or not a
#   private address (review K2),
# - the server fails its health check (not a Valhalla / Atlas map matching
#   not ready),
# - the server became unavailable or the day's time budget ran out while
#   snapping (circuit breaker, review M1): the next run tries again.
#
# Shadow dry run (GTFS_WALK_SNAP_SHADOW_SCOPE=all, Gtfs::Walk::ShadowSnap):
# after the live snap, the legs scope `all` would add are snapped with their
# own time budget and only logged; skipped when the live breaker opened.
class Gtfs::Walk::DaySnap
  Outcome = Struct.new(:legs, :stats, :summary, :skipped, keyword_init: true)
  BUDGET_TAG = '[GTFS walk] TIME BUDGET'
  LegOutcome = Struct.new(:leg, :result, keyword_init: true)

  # rides: Gtfs::Walk::Rides ([[started_at, ended_at, id], ...])
  def initialize(user, from_ts, to_ts, rides:, privacy_zones: nil, dry_run: Gtfs::Walk::Config.dry_run?,
                 points: nil, client: nil, breaker: nil, logger: Rails.logger, scope: Gtfs::Walk::Config.scope,
                 shadow_scope: Gtfs::Walk::Config.shadow_scope, shadow_breaker: nil)
    @user = user
    @from_ts = from_ts.to_i
    @to_ts = to_ts.to_i
    @rides = rides
    @privacy_zones = privacy_zones
    @dry_run = dry_run
    @points = points
    @client = client
    @breaker = breaker
    @logger = logger
    @scope = scope.to_s
    @shadow_scope = shadow_scope
    @shadow_breaker = shadow_breaker
  end

  def call
    return excluded if Gtfs::Walk::Config.excluded?(@user)

    problem = setup_problem
    return skip('not_configured', problem) if problem

    breaker = @breaker || Gtfs::Walk::Breaker.new # the budget includes the health check (review N8)
    client = @client || Gtfs::Walk::BaseClient.build
    client.budget = breaker if client.respond_to?(:budget=)
    begin
      client.healthy!
    rescue Gtfs::Walk::BaseClient::Error => e
      return skip('valhalla_unavailable', e.message)
    end

    snap(client, breaker)
  end

  private

  def snap(client, breaker)
    snapper = Gtfs::Walk::Snapper.new(client:, logger: @logger, breaker:)
    outcomes = legs(@scope).map { |leg| LegOutcome.new(leg:, result: snapper.call(leg.points)) }
    stats = totals(outcomes)
    if breaker.reason
      log(stats, breaker, " NOT SAVED (#{breaker.reason})")
      budget_warning(breaker, stats) if breaker.reason == 'time_budget'
      shadow(client, breaker, outcomes)
      return Outcome.new(legs: outcomes, stats:, skipped: breaker.reason)
    end

    summary = write(outcomes) unless @dry_run
    log(stats, breaker, summary ? " saved=#{summary}" : '')
    shadow(client, breaker, outcomes)
    Outcome.new(legs: outcomes, stats:, summary:)
  end

  def legs(scope)
    Gtfs::Walk::LegExtractor.new(day_points, rides: @rides, windows:, scope:).call
                            .select { |leg| leg.start_ts >= @from_ts && leg.start_ts < @to_ts }
  end

  def day_points = (@day_points ||= @points || load_points)

  def windows = (@windows ||= Gtfs::Matching::WindowDetector.new(day_points).call)

  def zones = (@zones ||= @privacy_zones || Users::PrivacyZones.new(@user).call)

  # Never writes and never changes the live outcome; any error is only logged.
  def shadow(client, live_breaker, outcomes)
    return unless @shadow_scope == 'all' && @scope != 'all'

    Gtfs::Walk::ShadowSnap.new(@user, day:, legs: legs('all'), live_legs: outcomes.map(&:leg), client:,
                                      zones:, live_breaker:, breaker: @shadow_breaker, logger: @logger).call
  rescue StandardError => e
    @logger&.warn("#{Gtfs::Walk::ShadowSnap::TAG} kind=error user=#{@user.id} day=#{day} " \
                  "error=#{e.class.name.delete(' ')}")
  end

  def write(outcomes)
    summary = Gtfs::Walk::LegWriter.new(@user).call(outcomes, from_ts: @from_ts, to_ts: @to_ts)
    # a snapped line may run through a zone the recorded points kept out of
    in_zones = Gtfs::Walk::Cleanup.apply_privacy_zones!(@user, zones:,
                                                         window: Gtfs::Walk::Cleanup.day_window(@from_ts, @to_ts))
    summary['in_privacy_zone'] = in_zones if in_zones.positive?
    summary
  end

  def setup_problem
    return 'GTFS_WALK_SNAP_EXCLUDE_EMAILS is not set or empty' unless Gtfs::Walk::Config.exclude_list_set?

    Gtfs::Walk::Config.url_problem if @client.nil?
  end

  def excluded
    deleted = @dry_run ? 0 : Gtfs::Walk::Cleanup.delete_for_user!(@user)
    Outcome.new(legs: [], stats: { 'deleted' => deleted }, skipped: 'excluded_user')
  end

  def skip(reason, message)
    @logger&.warn("[GTFS walk] user #{@user.id} #{day}: skipped, nothing sent or written: #{message}")
    Outcome.new(legs: [], stats: {}, skipped: reason)
  end

  # used_s: time spent on the day so far, health check included (review H-2:
  # shows how close a day comes to GTFS_WALK_DAY_BUDGET_SECS)
  def log(stats, breaker, suffix)
    fields = stats.merge('used_s' => breaker.used.round(1))
    @logger&.info("[GTFS walk] user #{@user.id} #{day}#{' DRY' if @dry_run}: " \
                  "#{fields.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}#{suffix}")
  end

  # One grep-able line per day lost to the time budget (review H-2): the
  # day is not written; the following nights retry it while it is in the
  # lookback, after that it stays unsnapped until it is snapped by hand
  # (docs/gtfs-walk.md, "Time budget"). gtfs:walk_shadow_report counts the
  # user-days that failed on more than one run.
  def budget_warning(breaker, stats)
    @logger&.warn("#{BUDGET_TAG} user=#{@user.id} day=#{day}#{' dry=1' if @dry_run} " \
                  "budget_s=#{breaker.budget.round(1)} used_s=#{breaker.used.round(1)} legs=#{stats['legs']} " \
                  "runs=#{stats['runs']}: day skipped, nothing written")
  end

  # The user's local day, as in Gtfs::MatchDay.day_range (from_ts is the
  # user's local midnight; in UTC it is still the day before east of UTC).
  def day
    zone = ActiveSupport::TimeZone[@user.try(:timezone_iana).to_s] || Time.zone
    Time.zone.at(@from_ts).in_time_zone(zone).to_date
  end

  def load_points
    buffer = Gtfs::Config::DAY_BUFFER_SECS
    Gtfs::Matching::PointLoader.new(@user, @from_ts - buffer, @to_ts + buffer, privacy_zones: @privacy_zones).call
  end

  def totals(outcomes)
    stats = Hash.new(0)
    stats['legs'] = outcomes.size
    outcomes.each do |o|
      %w[runs runs_snapped runs_rejected raw_parts gaps snap_cuts valhalla_errors valhalla_unavailable valhalla_skipped
         stationary_clouds].each { |k| stats[k] += o.result.stats[k].to_i }
      stats['legs_snapped'] += 1 if o.result.parts.any? { |p| p[:source] == 'valhalla' }
    end
    stats.to_h
  end
end
