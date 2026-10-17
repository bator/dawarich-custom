# frozen_string_literal: true

# Matches and saves one local day (user's time zone) of one user. Runs under
# a per-user advisory lock, so days of the same user are processed one after
# the other even if several jobs or a rake task run at the same time.
class Gtfs::MatchDay
  class Busy < StandardError; end

  Outcome = Struct.new(:date, :stats, :summary, :matches, keyword_init: true)

  def initialize(user, date, dry_run: false, logger: Rails.logger)
    @user = user
    @date = date.to_date
    @dry_run = dry_run
    @logger = logger
  end

  def call
    lock = ActiveRecord::Base.with_advisory_lock_result(lock_name, timeout_seconds: 0) { run }
    raise Busy, "matching of user #{@user.id} is already running" unless lock.lock_was_acquired?

    lock.result
  end

  # The user's current local date (review A12: not the app time zone).
  def self.today_for(user)
    (ActiveSupport::TimeZone[user.timezone_iana.to_s] || Time.zone).today
  end

  def self.day_range(user, date)
    zone = ActiveSupport::TimeZone[user.timezone_iana] || Time.zone
    from = zone.local(date.year, date.month, date.day).to_i
    to = zone.local(date.year, date.month, date.day).advance(days: 1).to_i
    [from, to]
  end

  # Also taken by gtfs:walk_snap (review M2).
  def self.lock_name(user) = "gtfs_match_user_#{user.id}"

  private

  def lock_name
    self.class.lock_name(@user)
  end

  def run
    feed_set = Gtfs::Matching::FeedSet.for_user(@user)
    @privacy_zones = Users::PrivacyZones.new(@user).call
    from_ts, to_ts = self.class.day_range(@user, @date)
    result = Gtfs::SegmentMatcher.new(@user, feed_set:, privacy_zones: @privacy_zones).match(from_ts, to_ts)
    evaluated = feed_set.covering(@date).keys
    summary = save(result, feed_set, from_ts, to_ts, evaluated) unless @dry_run
    log(result, evaluated, summary, feed_set)
    walk_snap(result, from_ts, to_ts)
    Outcome.new(date: @date, stats: result.stats, summary:, matches: result.matches)
  end

  # Also applies the user's privacy zones to their older `auto` rides
  # (review M2: a zone added later), which matching would not revisit.
  def save(result, feed_set, from_ts, to_ts, evaluated)
    summary = Gtfs::SegmentWriter.new(@user, feed_set:)
                                 .call(result.matches, from_ts:, to_ts:, evaluated_feed_ids: evaluated)
    summary.cleaned = Gtfs::SegmentCleanup.apply_privacy_zones!(@user, zones: @privacy_zones)
    Gtfs::Walk::Cleanup.safely('privacy zone cleanup', logger: @logger) do
      Gtfs::Walk::Cleanup.apply_privacy_zones!(@user, zones: @privacy_zones,
                                                      window: Gtfs::Walk::Cleanup.day_window(from_ts, to_ts))
    end
    summary
  end

  # Walking legs next to the rides, snapped to footpaths with Valhalla
  # (docs/gtfs-walk.md). Off unless GTFS_WALK_SNAP_ENABLED; a failure is
  # logged and never fails the ride matching. The rides are the saved ones
  # (same list as gtfs:walk_snap, review M5); a dry match saved nothing.
  def walk_snap(result, from_ts, to_ts)
    return unless Gtfs::Walk::Config.enabled?

    rides = @dry_run ? Gtfs::Walk::Rides.from_matches(result.matches) : Gtfs::Walk::Rides.saved(@user, from_ts, to_ts)
    Gtfs::Walk::DaySnap.new(@user, from_ts, to_ts, rides:, privacy_zones: @privacy_zones,
                            dry_run: @dry_run || Gtfs::Walk::Config.dry_run?, logger: @logger).call
  rescue StandardError => e
    @logger.warn("[GTFS walk] user #{@user.id} #{@date}: #{e.class}: #{e.message}")
    nil
  end

  def log(result, evaluated, summary, feed_set)
    missing = feed_set.feeds.reject { |f| evaluated.include?(f.id) }.map(&:key)
    message = "[GTFS match] user #{@user.id} #{@date}: #{result.stats.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}"
    message += " saved=#{summary.to_h.compact}" if summary
    message += " no_timetable_for=#{missing.join(',')}" if missing.any?
    @logger.info(message)
  end
end
