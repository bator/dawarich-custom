# frozen_string_literal: true

# Frequent routes (docs/corridors.md). DRY_RUN=1 prints without writing.
namespace :corridors do
  desc 'Build the frequent routes of one user: bin/rails "corridors:build[USER_ID]" (DRY_RUN=1: print only)'
  task :build, [:user_id] => :environment do |_, args|
    user = User.find(args[:user_id])
    routes = Corridors::Builder.new(user).call(dry_run: ENV['DRY_RUN'].present?)
    routes.each do |r|
      puts format('%-8<mode>s %3<trips>d trips  %5.2<km>f km  spread p50 %4.1<p50>f m  p90 %5.1<p90>f m  gaps %<gaps>s',
                  mode: r.mode, trips: r.trips, km: Corridors::Geometry.length(r.line) / 1000.0,
                  p50: r.spread_p50.to_f, p90: r.spread_p90.to_f, gaps: r.gaps.inspect)
    end
    puts "#{routes.size} frequent route(s)#{' (dry run, nothing stored)' if ENV['DRY_RUN'].present?}"
  end

  desc 'Snap tracks onto the frequent routes: bin/rails "corridors:snap[USER_ID,DAYS]" (DRY_RUN=1: print only)'
  task :snap, %i[user_id days] => :environment do |_, args|
    user = User.find(args[:user_id])
    days = (args[:days] || 3).to_i
    results = Corridors::Snapper.new(user).call(since: days.days.ago, dry_run: ENV['DRY_RUN'].present?)
    results.group_by(&:outcome).each { |outcome, list| puts "#{outcome}: #{list.size}" }
    results.select { |r| r.corridor_id }.first(20).each do |r|
      puts "  track #{r.track_id}: #{r.outcome} (route #{r.corridor_id}, #{(r.share.to_f * 100).round}% inside)"
    end
  end

  desc 'Put back the geometry of the snapped tracks: bin/rails "corridors:revert[USER_ID]" (DRY_RUN=1: print only)'
  task :revert, [:user_id] => :environment do |_, args|
    user = User.find(args[:user_id])
    results = Corridors::Snapper.new(user).revert(dry_run: ENV['DRY_RUN'].present?)
    results.group_by(&:outcome).each { |outcome, list| puts "#{outcome}: #{list.size}" }
  end
end
