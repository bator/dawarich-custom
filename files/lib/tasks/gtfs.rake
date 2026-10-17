# frozen_string_literal: true

namespace :gtfs do
  desc 'Create/refresh feed rows from config/gtfs_feeds.yml (new feeds start disabled)'
  task seed_feeds: :environment do
    Gtfs::FeedRegistry.seed!.each do |feed|
      puts format('%-18<key>s enabled=%-5<enabled>s url=%<url>s',
                  key: feed.key, enabled: feed.enabled, url: feed.source_url.presence || '-')
    end
  end

  desc 'Download (if changed) and import one feed: bin/rails "gtfs:import[budapest]" (FORCE=1 to re-import)'
  task :import, [:key] => :environment do |_t, args|
    feed = Gtfs::Feed.find_by!(key: args.fetch(:key))
    download = Gtfs::FeedDownloader.new(feed).call
    if download.status == :not_modified
      feed.update!(last_checked_at: Time.current)
      puts "#{feed.key}: not modified"
      next
    end

    # ETag/Last-Modified are stored by the importer only after a successful import.
    result = Gtfs::FeedImporter.new(feed, download.tempfile.path,
                                    force: ENV['FORCE'].present?, sha256: download.sha256,
                                    etag: download.etag, last_modified: download.last_modified).call
    puts "#{feed.key}: #{result.status} (version #{result.version})"
  ensure
    download&.tempfile&.close!
  end

  desc 'Import a local GTFS zip: bin/rails "gtfs:import_file[budapest,/path/gtfs.zip]" (FORCE=1 to re-import)'
  task :import_file, %i[key path] => :environment do |_t, args|
    feed = Gtfs::Feed.find_by(key: args.fetch(:key)) || Gtfs::FeedRegistry.seed!.find { |f| f.key == args[:key] }
    abort "unknown feed #{args[:key]} (add it to config/gtfs_feeds.yml)" unless feed

    result = Gtfs::FeedImporter.new(feed, args.fetch(:path), force: ENV['FORCE'].present?).call
    feed.reload
    puts "#{feed.key}: #{result.status} (version #{result.version}) valid #{feed.valid_from}..#{feed.valid_until}"
    if result.status == :imported
      puts JSON.pretty_generate(feed.import_stats.slice('rows', 'timings', 'total_secs',
                                                        'max_rss_mb'))
    end
  end

  desc 'Enqueue the sync of all enabled feeds (same as the daily cron job)'
  task sync: :environment do
    Gtfs::SyncAllFeedsJob.perform_later
    puts 'Gtfs::SyncAllFeedsJob enqueued (queue: gtfs)'
  end

  desc 'Show feed status, validity and expiry warnings'
  task status: :environment do
    Gtfs::Feed.order(:key).each do |f|
      line = '%-18<key>s %-9<status>s enabled=%-5<enabled>s v%-3<v>d valid %<from>s..%<to>s imported %<at>s%<err>s'
      puts format(line,
                  key: f.key, status: f.status, enabled: f.enabled, v: f.active_version, from: f.valid_from || '?',
                  to: f.valid_until || '?', at: f.last_imported_at&.iso8601 || '-',
                  err: f.last_error.present? ? " ERROR: #{f.last_error.truncate(120)}" : '')
    end
    Gtfs::ExpiryCheck.call.each do |e|
      puts "WARNING: #{e.feed.key} #{e.state == :expired ? 'EXPIRED' : 'expires soon'} (valid until #{e.valid_until})"
    end
  end

  desc 'Delete superseded GTFS versions now (also recovers feeds stuck in "importing" after a killed import)'
  task cleanup: :environment do
    Gtfs::Feed.find_each { |feed| Gtfs::CleanupOldVersionsJob.perform_now(feed.id) }
  end
end
