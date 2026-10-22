# frozen_string_literal: true

# Walking legs snapped with Valhalla (docs/gtfs-walk.md).
module GtfsWalkTasks
  module_function

  # Same per-user advisory lock as Gtfs::MatchDay (review M2): a running
  # match or another walk_snap of the user makes this abort.
  def with_user_lock(user, &)
    lock = ActiveRecord::Base.with_advisory_lock_result(Gtfs::MatchDay.lock_name(user), timeout_seconds: 0, &)
    abort "matching of user #{user.id} is running, try again later" unless lock.lock_was_acquired?

    lock.result
  end

  # SCOPE=transit|all overrides GTFS_WALK_SNAP_SCOPE for this run
  def scope_from_env
    value = ENV['SCOPE'].to_s.strip.downcase
    return Gtfs::Walk::Config.scope if value.empty?

    Gtfs::Walk::Config::SCOPES.include?(value) ? value : abort("SCOPE must be one of #{Gtfs::Walk::Config::SCOPES.join('/')}")
  end

  # The shadow dry run belongs to the nightly matching only (shadow_scope: nil).
  def snap_day(user, date, dry_run:, scope: Gtfs::Walk::Config.scope)
    from_ts, to_ts = Gtfs::MatchDay.day_range(user, date)
    rides = Gtfs::Walk::Rides.saved(user, from_ts, to_ts) # the same list as MatchDay (review M5)
    outcome = Gtfs::Walk::DaySnap.new(user, from_ts, to_ts, rides:, dry_run:, scope:, shadow_scope: nil).call
    puts "#{date}#{' DRY' if dry_run}: scope=#{scope} rides=#{rides.size} " \
         "#{outcome.stats.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}" \
         "#{" skipped=#{outcome.skipped}" if outcome.skipped}#{" saved=#{outcome.summary}" if outcome.summary}"
    outcome.legs.each { |o| puts leg_line(user, o) }
    outcome.legs.map do |o|
      { date: date.to_s, started_at: o.leg.start_ts, ended_at: o.leg.end_ts, parts: o.result.parts,
        stats: o.result.stats }
    end
  end

  def leg_line(user, outcome)
    m = outcome.result.stats['metrics']
    s = outcome.result.stats
    zone = user.timezone_iana
    at = ->(ts) { Time.zone.at(ts).in_time_zone(zone).strftime('%H:%M') }
    format('  %<a>s-%<b>s raw=%<raw>dm drawn=%<drawn>dm ratio=%<r>.2f med=%<med>.1fm p95=%<p95>.1fm ' \
           'within25=%<w>d%% runs=%<runs>d snapped=%<ok>d rejected=%<rej>d raw_parts=%<rp>d gaps=%<gaps>d %<why>s',
           a: at.call(outcome.leg.start_ts), b: at.call(outcome.leg.end_ts), raw: m['raw_m'], drawn: m['drawn_m'],
           r: m['ratio'] || 0, med: m['median_m'], p95: m['p95_m'], w: (m['within_25_share'] * 100).round,
           runs: s['runs'].to_i, ok: s['runs_snapped'].to_i, rej: s['runs_rejected'].to_i,
           rp: s['raw_parts'].to_i, gaps: s['gaps'].to_i, why: s['reasons'].presence&.to_s)
  end
end

namespace :gtfs do
  desc 'Snap walking legs: bin/rails "gtfs:walk_snap[USER_ID,2026-10-01,2026-10-09]" ' \
       '(dry run unless WRITE=1 and GTFS_WALK_SNAP_ENABLED=true; SCOPE=all|transit overrides ' \
       'GTFS_WALK_SNAP_SCOPE; JSON=file dumps the legs)'
  task :walk_snap, %i[user from to] => :environment do |_t, args|
    user = User.find_by(id: args.fetch(:user)) || User.find_by(email: args.fetch(:user)) ||
           abort("unknown user #{args[:user]}")
    abort 'this account is excluded from walk snapping' if Gtfs::Walk::Config.excluded?(user)
    write = ENV['WRITE'] == '1'
    abort 'WRITE=1 needs GTFS_WALK_SNAP_ENABLED=true' if write && !Gtfs::Walk::Config.enabled?
    dry_run = !write || Gtfs::Walk::Config.dry_run?
    scope = GtfsWalkTasks.scope_from_env
    # LegWriter replaces the whole day: the next match with the configured
    # scope would silently delete legs written with another one (review K4)
    if write && scope != Gtfs::Walk::Config.scope && ENV['FORCE'] != '1'
      abort "SCOPE=#{scope} differs from GTFS_WALK_SNAP_SCOPE=#{Gtfs::Walk::Config.scope}; the next match of " \
            'the day would delete these legs (FORCE=1 to write anyway)'
    end
    from = Date.parse(args.fetch(:from))
    to = Date.parse(args[:to] || args[:from])
    dump = (from..to).flat_map do |date|
      GtfsWalkTasks.with_user_lock(user) { GtfsWalkTasks.snap_day(user, date, dry_run:, scope:) }
    end
    File.write(ENV['JSON'], JSON.pretty_generate(dump)) if ENV['JSON'].present?
  end

  desc 'Summarise the shadow dry run from the logs: ' \
       'journalctl -u dawarich-worker --since "7 days ago" | bin/rails gtfs:walk_shadow_report ' \
       '(or FILE=log; DAYS=N: only the last N days; JSON=1: machine readable). Persists nothing.'
  task walk_shadow_report: :environment do
    input = ENV['FILE'].present? ? File.foreach(ENV['FILE']) : $stdin.each_line
    days = ENV['DAYS'].presence && Integer(ENV['DAYS'], 10)
    report = Gtfs::Walk::ShadowReport.new(input, days:)
    puts ENV['JSON'] == '1' ? JSON.pretty_generate(report.call) : report.to_s
  end

  desc 'Count walking legs whose stored drawn geometry is missing or outdated (e.g. written by older code ' \
       'after a rollback, review A-8-2 / A-9-3); WRITE=1: rebuild it from parts. Dry run by default ' \
       '(like walk_snap, review A-9-1). Derived data only; takes no lock.'
  task walk_refresh_drawn: :environment do
    stale = TransitWalkLeg.stale_drawn
    puts "walking legs with missing or outdated drawn geometry: #{stale.count}"
    unless ENV['WRITE'] == '1'
      puts 'dry run, nothing written (WRITE=1 to rebuild them)'
      next
    end

    refreshed = 0
    stale.in_batches(of: 500) { |batch| refreshed += TransitWalkLeg.refresh_drawn!(batch.ids) }
    puts "refreshed: #{refreshed}, still stale: #{TransitWalkLeg.stale_drawn.count}"
  end
end
