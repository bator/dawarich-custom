# frozen_string_literal: true

# Phase 2: matching of points against the GTFS timetables (docs/gtfs.md).
# Helpers of the tasks below, in a module instead of top-level methods
# (review A9: those would become private methods of every Object).
module GtfsMatchTasks
  module_function

  def user!(id)
    User.find_by(id:) || User.find_by(email: id) || abort("unknown user #{id}")
  end

  def print_segment(segment_or_match, zone)
    s = segment_or_match
    if s.is_a?(TransitSegment)
      attrs = s.attributes.symbolize_keys
      flag = s.uncertain? ? ' uncertain' : ''
    else
      attrs = Gtfs::SegmentAttributes.new(s).to_h
      flag = attrs[:debug]['uncertain'] ? ' uncertain' : ''
    end
    start = Time.zone.at(s.started_at).in_time_zone(zone)
    finish = Time.zone.at(s.ended_at).in_time_zone(zone)
    puts format('  %<d>s %<a>s-%<b>s  %-8<line>s %<from>s -> %<to>s  conf=%<c>.2f%<flag>s',
                d: start.to_date, a: start.strftime('%H:%M'), b: finish.strftime('%H:%M'),
                line: attrs[:route_short_name], from: attrs[:boarding_stop_name], to: attrs[:alighting_stop_name],
                c: s.confidence, flag:)
  end
end

namespace :gtfs do
  desc 'Match points against the timetables: bin/rails "gtfs:match[USER_ID,2026-10-01,2026-10-09]" ' \
       '(DRY_RUN=1 = only print)'
  task :match, %i[user from to] => :environment do |_t, args|
    user = GtfsMatchTasks.user!(args.fetch(:user))
    from = Date.parse(args.fetch(:from))
    to = Date.parse(args[:to] || args[:from])
    dry_run = ENV['DRY_RUN'].present?
    total = Hash.new(0)
    (from..to).each do |date|
      outcome = Gtfs::MatchDay.new(user, date, dry_run:).call
      outcome.stats.each { |k, v| total[k] += v }
      shown = outcome.stats.slice('points', 'windows', 'candidates', 'matches', 'ms')
      counts = shown.map { |k, v| "#{k}=#{v}" }.join(' ')
      puts "#{date}: #{counts}" \
           "#{" saved=#{outcome.summary.to_h}" if outcome.summary}"
      outcome.matches.each { |m| GtfsMatchTasks.print_segment(m, user.timezone_iana) }
    end
    puts "total: #{total.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}"
  end

  desc 'List saved transit segments: bin/rails "gtfs:segments[USER_ID,2026-10-01,2026-10-09]"'
  task :segments, %i[user from to] => :environment do |_t, args|
    user = GtfsMatchTasks.user!(args.fetch(:user))
    from_ts, = Gtfs::MatchDay.day_range(user, Date.parse(args.fetch(:from)))
    _, to_ts = Gtfs::MatchDay.day_range(user, Date.parse(args[:to] || args[:from]))
    user.transit_segments.where(started_at: from_ts...to_ts).order(:started_at).each do |segment|
      GtfsMatchTasks.print_segment(segment, user.timezone_iana)
    end
  end

  desc 'Start or resume the backfill of past days: bin/rails "gtfs:backfill[USER_ID]" (RESTART=1 to start over)'
  task :backfill, [:user] => :environment do |_t, args|
    user = GtfsMatchTasks.user!(args.fetch(:user))
    abort 'gtfs_enabled is not set for this user' unless Gtfs::UserSettings.new(user).enabled?
    puts Gtfs::Backfill.start!(user, restart: ENV['RESTART'].present?).to_json
  end

  desc 'Cancel a running backfill: bin/rails "gtfs:backfill_cancel[USER_ID]"'
  task :backfill_cancel, [:user] => :environment do |_t, args|
    puts Gtfs::Backfill.cancel!(GtfsMatchTasks.user!(args.fetch(:user))).to_json
  end

  desc 'Show the backfill state: bin/rails "gtfs:backfill_status[USER_ID]"'
  task :backfill_status, [:user] => :environment do |_t, args|
    puts Gtfs::Backfill.status(GtfsMatchTasks.user!(args.fetch(:user))).to_json
  end

  desc 'Remove rides without points and auto rides in privacy zones: bin/rails "gtfs:segment_cleanup[USER_ID]"'
  task :segment_cleanup, [:user] => :environment do |_t, args|
    user = GtfsMatchTasks.user!(args.fetch(:user))
    zones = Gtfs::SegmentCleanup.apply_privacy_zones!(user)
    orphans = Gtfs::SegmentCleanup.delete_orphans!(user.transit_segments)
    puts "removed #{zones} ride(s) in privacy zones, #{orphans} ride(s) without points"
    walk = Gtfs::Walk::Cleanup
    walk_zones = walk.safely('privacy zone cleanup') { walk.apply_privacy_zones!(user) }
    walk_stale = walk.safely('stale leg cleanup') { walk.delete_stale!(TransitWalkLeg.where(user_id: user.id)) }
    puts "removed #{walk_zones} walking leg(s) in privacy zones, #{walk_stale} stale walking leg(s)"
  end
  desc 'Transport mode of the track segments under confirmed rides (Gtfs::TrackModes): ' \
       'USER_ID= (default: every opted-in user), DAYS= (default 7). Dry run by default, WRITE=1 to change.'
  task track_modes: :environment do
    days = (ENV['DAYS'] || Gtfs::TrackModesJob::DAYS).to_i
    users = Gtfs::UserSettings.opted_in_users
    users = users.where(id: ENV['USER_ID']) if ENV['USER_ID'].present?
    users.find_each do |user|
      today = Gtfs::MatchDay.today_for(user)
      from, = Gtfs::MatchDay.day_range(user, today - days)
      _, to = Gtfs::MatchDay.day_range(user, today)
      changes = Gtfs::TrackModes.new(user, from:, to:).call(dry_run: ENV['WRITE'] != '1')
      changes.each do |c|
        puts "user #{user.id} track #{c.track_id} segment #{c.segment_id}: #{c.from} -> #{c.to || 'detected'}" \
             "#{" (ride #{c.ride_id})" if c.ride_id}"
      end
      puts "user #{user.id}: #{changes.size} segment(s)#{' (dry run, WRITE=1 to change)' unless ENV['WRITE'] == '1'}"
    end
  end
  desc 'Test cases for the matcher on the live data, dry (Gtfs::MatchCases): the reviewed rides of the last ' \
       'DAYS (default 90) and config/gtfs_match_cases.yml. USER_ID= limits it; FILE_ONLY=1 skips the reviews; ' \
       'VERBOSE=1 lists the passes too. Exits 1 when a case fails.'
  task match_cases: :environment do
    results = Gtfs::MatchCases.new(days: (ENV['DAYS'] || 90).to_i, user_id: ENV['USER_ID'].presence,
                                   reviews: ENV['FILE_ONLY'] != '1').call
    clock = ->(t) { t ? Time.zone.at(t).in_time_zone('Europe/Budapest').strftime('%H:%M') : '?' }
    label = ->(d) { d ? "#{d[:line]} #{d[:board]} -> #{d[:alight]} #{clock.call(d[:from])}-#{clock.call(d[:to])}" : '-' }
    results.sort_by { |r| [r.pass ? 1 : 0, r.date, r.user_id] }.each do |r|
      next if r.pass && ENV['VERBOSE'] != '1'

      status = if r.skipped then 'skip' elsif r.pass then 'ok' else 'FAIL' end
      puts format('%-4s %-9s %s u%-2d %-38s %-8s want: %s | got: %s%s', status, r.kind, r.date, r.user_id,
                  r.case_id, r.grade, label.call(r.expected), label.call(r.found),
                  r.found&.dig(:confidence) ? " (#{r.found[:confidence]})" : '')
    end
    by = results.reject(&:skipped).group_by(&:kind).transform_values { |rs| "#{rs.count(&:pass)}/#{rs.size}" }
    grades = results.group_by(&:grade).transform_values(&:size)
    run = results.reject(&:skipped)
    puts "passed #{run.count(&:pass)}/#{run.size} (skipped #{results.count(&:skipped)}: no timetable that day) " \
         "#{by} grades #{grades}"
    exit 1 unless results.all?(&:pass)
  end
end
