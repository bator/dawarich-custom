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
    rides = begin
      TrackPick::MapImage.rides(comparison)
    rescue StandardError => e
      warn "gtfs rides failed: #{e.class}: #{e.message}"
      []
    end
    # the day in segments, each picked on its own (TrackPick::Segments, since 2026-11-08)
    segments = TrackPick::Segments.new(comparison, rides)
    segs = segments.call
    if segs.empty?
      puts 'no segment to pick (nobody moved): nothing posted'
      next
    end
    # split messages (2026-11-18): a header + one message per segment with its own image
    extra = { summary: TrackPick::Message.summary(comparison),
              dropped_line: TrackPick::Message.dropped_line(segments.dropped) }
    file = JSON.parse(JSON.generate(segments.to_h(**extra)))
    picks = TrackPick::Message.initial_picks(file['segments'])
    images = segs.to_h do |seg|
      png = begin
        TrackPick::MapImage.build_segment_image(comparison, seg)
      rescue StandardError => e
        warn "segment #{seg.index} image failed: #{e.class}: #{e.message}"
        nil
      end
      [seg.index.to_s, png]
    end
    header = TrackPick::Message.split_header_payload(date, file, picks)
    seg_payloads = file['segments'].map do |s|
      [s, TrackPick::Message.split_segment_payload(date, s, picks, image: images[s['index'].to_s].present?)]
    end
    if (decided = TrackPick::Config.decision(date))
      puts "#{TrackPick::Message.decided_line(decided)} -> no choice offered, nothing posted"
      next
    end
    if dry
      dir = ENV['TRACK_PICK_MAP_DIR'].presence || '/tmp'
      images.each { |i, png| File.binwrite(File.join(dir, TrackPick::Message.segment_filename(date, i)), png) if png }
      File.write(File.join(dir, "track-pick-#{date.iso8601}-payload.json"),
                 JSON.pretty_generate([header] + seg_payloads.map(&:last)))
      puts "DRY RUN: nothing sent, nothing written to the database (images and payloads in #{dir})"
      puts header[:embeds].first[:description]
      seg_payloads.each do |s, payload|
        puts "#{payload[:embeds].first[:title]}: " +
             payload[:components].flat_map { |r| r[:components] }.map { |c| "#{c[:label]}=#{c[:custom_id]}" }.join(' | ')
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
    client = Gtfs::Discord::Client.new
    channel = TrackPick::Config.channel_id
    posted = []
    # up to 9 messages in a row: Discord allows ~5 per 5 s per channel, so wait when it says so
    post = lambda do |payload, files|
      tries = 0
      begin
        client.post_message(channel, payload, files:)
      rescue Gtfs::Discord::Client::RateLimited => e
        raise if (tries += 1) > 5

        sleep(e.retry_after.to_f + 0.2)
        retry
      end
    end
    begin
      segments.save!(**extra) # a click refers to a segment by its number
      TrackPick::Segments.save_picks!(date, picks)
      head = post.call(header, [])
      posted << head['id']
      segments.save!(message_id: head['id'].to_s, **extra)
      ids = {}
      seg_payloads.each do |s, payload|
        png = images[s['index'].to_s]
        files = png ? [Gtfs::Discord::Client::Upload.new(TrackPick::Message.segment_filename(date, s['index']), png, 'image/png')] : []
        msg = post.call(payload, files)
        posted << msg['id']
        ids[s['index'].to_s] = msg['id'].to_s
        segments.save!(message_id: head['id'].to_s, segment_messages: ids, **extra)
      end
      File.write(marker, "#{head['id']}\n")
      puts "posted header #{head['id']} and #{ids.size} segment message(s)"
    rescue StandardError
      posted.each do |id|
        client.delete_message(channel, id)
      rescue StandardError => e
        warn "could not delete #{id}: #{e.class}"
      end
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
