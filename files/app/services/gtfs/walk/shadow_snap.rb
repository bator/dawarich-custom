# frozen_string_literal: true

# Shadow dry run of scope `all` (GTFS_WALK_SNAP_SHADOW_SCOPE=all, see
# docs/gtfs-walk.md): after the live snap of a day, the walking legs scope
# `all` would add (those not overlapping a live leg) go through Atlas and the
# quality gates like live ones, and are only LOGGED. Nothing is written,
# not even in a non-dry run; the points table is only read (by DaySnap).
#
# - runs only after the live snap, and not at all when the live breaker
#   opened (outage or used-up budget: that day is retried anyway);
# - has its own time budget (GTFS_WALK_SHADOW_BUDGET_SECS) and breaker: once
#   it opens, the remaining legs are not sent (`not_run`);
# - DaySnap only calls it for accounts that are not excluded, with points
#   outside the privacy zones (PointLoader); a leg whose snapped line touches
#   a zone is flagged `in_zone=1` (it would not be kept);
# - a leg touches a zone when any drawn part comes within the radius
#   (Gtfs::Walk::ZoneCheck, the line, not only its vertices: review K2);
# - logs no coordinates and only coarse times (review A3): the start in the
#   user's local time floored to START_SLOT_MINUTES and the duration in whole
#   minutes. One `kind=leg` line per leg and one `kind=day` line, `key=value`,
#   all carrying the same random `run` id, for gtfs:walk_shadow_report (which
#   counts only the latest run of a user-day: review A4).
class Gtfs::Walk::ShadowSnap
  TAG = '[GTFS walk shadow]'
  START_SLOT_MINUTES = 15

  def initialize(user, day:, legs:, live_legs:, client:, zones:, live_breaker: nil, breaker: nil,
                 logger: Rails.logger)
    @user = user
    @day = day
    @legs = legs
    @live_legs = live_legs
    @client = client
    @zones = zones
    @live_breaker = live_breaker
    @breaker = breaker
    @logger = logger
    @run = SecureRandom.hex(4)
  end

  def call
    return day_line(skipped: "live_breaker_#{@live_breaker.reason}") if @live_breaker&.reason

    breaker = @breaker || Gtfs::Walk::Breaker.new(budget_secs: Gtfs::Walk::Config::SHADOW_BUDGET_SECS)
    @client.budget = breaker if @client.respond_to?(:budget=)
    snapper = Gtfs::Walk::Snapper.new(client: @client, logger: nil, breaker:)
    counts = Hash.new(0)
    extra_legs.each_with_index do |leg, index|
      if breaker.open?
        counts['not_run'] += 1
        next
      end

      result = snapper.call(leg.points)
      outcome = breaker.reason ? 'aborted' : Gtfs::Walk::LegWriter.source_for(result.parts)
      counts[outcome] += 1
      leg_line(index, leg, result, outcome)
    end
    day_line(counts:, breaker:)
  end

  # scope `all` legs that do not overlap a live (scope `transit`) leg
  def extra_legs
    @extra_legs ||= @legs.reject do |leg|
      @live_legs.any? { |live| leg.start_ts <= live.end_ts && leg.end_ts >= live.start_ts }
    end
  end

  private

  def leg_line(index, leg, result, outcome)
    s = result.stats
    m = s['metrics'] || {}
    fields = {
      kind: 'leg', run: @run, user: @user.id, day: @day, leg: index + 1, start: slot(leg.start_ts),
      dur_min: ((leg.end_ts - leg.start_ts) / 60.0).round, points: leg.points.size,
      raw_m: m['raw_m'], drawn_m: m['drawn_m'], outcome:,
      ratio: m['ratio'], median_m: m['median_m'], p95_m: m['p95_m'], within25: m['within_25_share'],
      runs: s['runs'].to_i, snapped: s['runs_snapped'].to_i, rejected: s['runs_rejected'].to_i,
      raw_parts: s['raw_parts'].to_i, gaps: s['gaps'].to_i, stationary: s['stationary_clouds'].to_i,
      errors: s['valhalla_errors'].to_i, in_zone: in_zone?(result.parts) ? 1 : 0,
      reasons: reasons(s['reasons'])
    }
    log(fields)
  end

  # {"median=37m" => 1, "ratio=1.4" => 1} -> "median:1,ratio:1" (gate names only;
  # the values are in the metrics)
  def reasons(counts)
    counts.to_h.each_with_object(Hash.new(0)) { |(k, v), out| out[k.to_s.split('=').first] += v.to_i }
          .map { |k, v| "#{k}:#{v}" }.join(',').presence
  end

  def day_line(counts: {}, breaker: nil, skipped: nil)
    fields = { kind: 'day', run: @run, user: @user.id, day: @day, live_legs: @live_legs.size,
               candidates: @legs.size, extra: skipped ? nil : extra_legs.size, skipped: }
    %w[valhalla mixed raw aborted not_run].each { |k| fields[k] = counts[k].to_i } unless skipped
    if breaker
      fields[:budget_s] = Gtfs::Walk::Config::SHADOW_BUDGET_SECS
      fields[:used_s] = (Gtfs::Walk::Config::SHADOW_BUDGET_SECS - breaker.remaining).round(1)
      fields[:breaker] = breaker.reason
    end
    log(fields)
  end

  def log(fields)
    line = fields.map { |k, v| "#{k}=#{v.nil? ? '-' : v.to_s.delete(' ')}" }.join(' ')
    @logger&.info("#{TAG} #{line}")
  end

  # local start floored to the slot, e.g. 08:07:41 -> 08:00
  def slot(epoch)
    zone = ActiveSupport::TimeZone[@user.try(:timezone_iana).to_s] || Time.zone
    local = Time.zone.at(epoch).in_time_zone(zone)
    format('%<h>02d:%<m>02d', h: local.hour, m: local.min - (local.min % START_SLOT_MINUTES))
  end

  def in_zone?(parts) = Gtfs::Walk::ZoneCheck.touches?(parts, @zones)
end
