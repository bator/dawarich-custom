# frozen_string_literal: true

namespace :track_pick do
  desc 'Daily track comparison -> Discord buttons: track_pick:daily[YYYY-MM-DD] (default yesterday). DRY_RUN=1: print only'
  task :daily, [:date] => :environment do |_, args|
    zone = TrackPick::Config.zone
    date = args[:date].present? ? Date.iso8601(args[:date]) : (zone.now.to_date - 1)
    dry = ENV['DRY_RUN'].present? && ENV['DRY_RUN'] != '0'
    if (decided = TrackPick::Config.decision(date)) # A3: before any rendering
      puts "#{TrackPick::Message.decided_line(decided)} -> no choice offered, nothing posted"
      next
    end
    comparison = TrackPick::Comparison.new(date)
    puts comparison.to_text
    target = TrackPick::Config.target_user
    comparison.call.each do |s|
      next if s.user.id == target.id

      n = TrackPick::Copier.new(date, s.user, target).call(dry_run: true)
      puts "  ha #{TrackPick::Config.handle(s.user)} lesz kiválasztva: #{n} új pont kerülne #{TrackPick::Config.handle(target)} fiókjába"
    end
    rides = begin
      TrackPick::MapImage.rides(comparison)
    rescue StandardError => e
      warn "gtfs rides failed: #{e.class}: #{e.message}"
      []
    end
    sheet = begin
      TrackPick::MapImage.build_sheet(comparison, rides) # one image, one row per GTFS ride
    rescue StandardError => e
      warn "map sheet failed: #{e.class}: #{e.message}"
      nil
    end
    payload = TrackPick::Message.payload(comparison, sheet:, rides:)
    if (decided = TrackPick::Config.decision(date))
      puts "#{TrackPick::Message.decided_line(decided)} -> no choice offered, nothing posted"
      next
    end
    if dry
      dir = ENV['TRACK_PICK_MAP_DIR'].presence || '/tmp'
      path = sheet && File.join(dir, TrackPick::Message.sheet_filename(date))
      File.binwrite(path, sheet) if path
      puts "DRY RUN: nothing sent, nothing written to the database (map sheet: #{path || 'none'})"
      puts payload[:embeds].first[:description]
      payload[:components].each do |row|
        row[:components].each do |c|
          items = c[:options]&.map { |o| "#{o[:label]}=#{o[:value]}" } || [c[:label]]
          puts "#{c[:custom_id]}: #{items.join(' | ')}"
        end
      end
      next
    end
    abort 'Discord bot not configured' if TrackPick::Config.token.blank? || TrackPick::Config.channel_id.blank?
    if comparison.call.all? { |s| s.count.zero? }
      puts 'no points for any user: nothing posted'
      next
    end
    # K5: claim the posted marker first (exclusive), post, then write the id; roll back on failure
    marker = Pathname(TrackPick::Config::STATE_DIR).join("posted-#{date.iso8601}")
    FileUtils.mkdir_p(marker.dirname)
    if ENV['FORCE'].present? && marker.exist? && marker.read.strip != 'pending' # move aside, never delete
      marker.rename("#{marker}.replaced-#{Time.now.strftime('%Y%m%d-%H%M%S')}")
    end
    begin
      File.open(marker, File::WRONLY | File::CREAT | File::EXCL) { |f| f.write("pending\n") }
    rescue Errno::EEXIST
      puts "already posted (or posting) for #{date.iso8601} (#{marker}: #{marker.read.strip}); FORCE=1 to post again"
      next
    end
    begin
      files = TrackPick::Message.files(date, sheet)
      msg = Gtfs::Discord::Client.new.post_message(TrackPick::Config.channel_id, payload, files:)
      File.write(marker, "#{msg['id']}\n")
      puts "posted message #{msg['id']}"
    rescue StandardError
      marker.delete if marker.exist? && marker.read.strip == 'pending'
      raise
    end
  end

  desc 'Manual copy without Discord: track_pick:copy[YYYY-MM-DD,SOURCE_USER_ID,BP_USER_ID] ' \
       '(BP_USER_ID optional: inner city from that user; DRY_RUN=1 counts only)'
  task :copy, %i[date source_id bp_id] => :environment do |_, args|
    date = Date.iso8601(args[:date])
    users = TrackPick::Config.source_users.index_by(&:id)
    source = users[args[:source_id].to_i] or abort 'unknown source'
    bp = args[:bp_id].present? ? (users[args[:bp_id].to_i] or abort 'unknown inner-city source') : nil
    bp = nil if bp&.id == source.id
    dry = ENV['DRY_RUN'].present? && ENV['DRY_RUN'] != '0'
    n = if bp
          ActiveRecord::Base.transaction do
            TrackPick::Copier.new(date, source, scope: :outside).call(dry_run: dry) +
              TrackPick::Copier.new(date, bp, scope: :inside).call(dry_run: dry)
          end
        else
          TrackPick::Copier.new(date, source).call(dry_run: dry)
        end
    puts "#{dry ? 'would insert' : 'inserted'} #{n} points"
  end

  desc 'Show again the target points a pick hid for a ride: track_pick:unhide[YYYY-MM-DD]'
  task :unhide, [:date] => :environment do |_, args|
    date = Date.iso8601(args[:date])
    n = TrackPick::Hider.new(date).unhide
    puts "#{n} points shown again for #{date} (the decision itself stays; copied points stay)"
  end
end
