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
    images = begin
      TrackPick::MapImage.build_each(comparison)
    rescue StandardError => e
      warn "map images failed: #{e.class}: #{e.message}"
      []
    end
    budapest = begin
      TrackPick::MapImage.build_budapest(comparison)
    rescue StandardError => e
      warn "budapest maps failed: #{e.class}: #{e.message}"
      []
    end
    images, budapest = TrackPick::MapImage.fit_upload_limit(comparison, images, budapest) # A8
    payload = TrackPick::Message.payload(comparison, images:, budapest:)
    if (decided = TrackPick::Config.decision(date))
      puts "#{TrackPick::Message.decided_line(decided)} -> no choice offered, nothing posted"
      next
    end
    if dry
      dir = ENV['TRACK_PICK_MAP_DIR'].presence || '/tmp'
      paths = images.map { |s, png| [s, png, nil] }.concat(budapest.map { |s, png| [s, png, 'bp'] }).map do |s, png, sfx|
        path = File.join(dir, "#{date.iso8601}-#{TrackPick::Message.filename(s, sfx)}")
        File.binwrite(path, png)
        path
      end
      puts "DRY RUN: nothing sent, nothing written to the database (maps: #{paths.join(', ')})"
      puts "menu: #{payload[:components].first[:components].first[:options].map { |o| "#{o[:label]}=#{o[:value]} (#{o[:description]})" }.join(' | ')}"
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
      files = TrackPick::Message.files(images, budapest)
      msg = Gtfs::Discord::Client.new.post_message(TrackPick::Config.channel_id, payload, files:)
      File.write(marker, "#{msg['id']}\n")
      puts "posted message #{msg['id']}"
    rescue StandardError
      marker.delete if marker.exist? && marker.read.strip == 'pending'
      raise
    end
  end

  desc 'Manual copy without Discord: track_pick:copy[YYYY-MM-DD,SOURCE_USER_ID] (DRY_RUN=1 counts only)'
  task :copy, %i[date source_id] => :environment do |_, args|
    date = Date.iso8601(args[:date])
    source = TrackPick::Config.source_users.find { |u| u.id == args[:source_id].to_i } or abort 'unknown source'
    dry = ENV['DRY_RUN'].present? && ENV['DRY_RUN'] != '0'
    n = TrackPick::Copier.new(date, source).call(dry_run: dry)
    puts "#{dry ? 'would insert' : 'inserted'} #{n} points"
  end
end
