# frozen_string_literal: true

namespace :accuracy_gate do
  desc 'Hide points worse than the users\' gps_accuracy_threshold (AccuracyGate). USER_ID= limits it, ' \
       'DAYS= only the last days (default: all history). Dry run by default, WRITE=1 to hide.'
  task run: :environment do
    users = AccuracyGate.users
    users = users.where(id: ENV['USER_ID']) if ENV['USER_ID'].present?
    from_ts = ENV['DAYS'].present? ? ENV['DAYS'].to_i.days.ago.to_i : nil
    users.find_each do |user|
      r = AccuracyGate.new(user, from_ts:).call(dry_run: ENV['WRITE'] != '1')
      span = r.days.any? ? "#{r.days.first}..#{r.days.last}" : '-'
      puts "user #{user.id}: threshold #{r.threshold} m, #{r.hidden} point(s) on #{r.days.size} day(s) #{span}" \
           "#{' (dry run, WRITE=1 to hide)' unless ENV['WRITE'] == '1'}"
    end
  end

  desc 'Show again what the gate hid: bin/rails "accuracy_gate:undo[USER_ID,FROM,TO]" (dates, local days)'
  task :undo, %i[user from to] => :environment do |_t, args|
    user = User.find(args.fetch(:user))
    from = Date.parse(args.fetch(:from))
    to = Date.parse(args[:to].presence || args[:from])
    puts "user #{user.id}: #{AccuracyGate.undo(user, from:, to:)} point(s) shown again, tracks rebuilt for #{from}..#{to}"
  end
end
