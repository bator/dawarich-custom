# frozen_string_literal: true

namespace :gtfs do
  desc 'Compare imported row counts of the active version with the CSV row counts in a zip: ' \
       'bin/rails "gtfs:verify_counts[budapest,/path/gtfs.zip]"'
  task :verify_counts, %i[key path] => :environment do |_t, args|
    feed = Gtfs::Feed.find_by!(key: args.fetch(:key))
    files = { 'stops.txt' => Gtfs::Stop, 'routes.txt' => Gtfs::Route, 'trips.txt' => Gtfs::Trip,
              'stop_times.txt' => Gtfs::StopTime, 'frequencies.txt' => Gtfs::Frequency }
    stats = feed.import_stats.fetch('files', {})
    ok = true
    Gtfs::ZipReader.open(args.fetch(:path)) do |zip|
      files.each do |name, model|
        next unless zip.file?(name)

        csv_rows = 0
        zip.each_row(name) { csv_rows += 1 }
        db_rows = model.where(feed_id: feed.id, version: feed.active_version).count
        rejected = stats.dig(name, 'bad').to_i + stats.dig(name, 'skipped').to_i
        rejected += feed.import_stats['stop_times_duplicate_sequence'].to_i if name == 'stop_times.txt'
        match = csv_rows == db_rows + rejected
        ok &&= match
        puts format('%-10<key>s %-16<file>s zip=%<csv>9d db=%<db>9d rejected=%<rej>6d %<res>s',
                    key: feed.key, file: name, csv: csv_rows, db: db_rows, rej: rejected,
                    res: match ? 'OK' : 'MISMATCH')
      end
      if zip.file?('shapes.txt') && feed.import_shapes
        ids = Set.new
        zip.each_row('shapes.txt') { |r| ids << r['shape_id'] }
        db = Gtfs::Shape.where(feed_id: feed.id, version: feed.active_version).count
        dropped = feed.import_stats['shapes_dropped_single_point'].to_i
        match = ids.size == db + dropped
        ok &&= match
        puts format('%-10<key>s %-16<file>s zip=%<csv>9d db=%<db>9d dropped=%<d>7d %<res>s (distinct shape_id)',
                    key: feed.key, file: 'shapes.txt', csv: ids.size, db:, d: dropped, res: match ? 'OK' : 'MISMATCH')
      end
    end
    abort "#{feed.key}: COUNT MISMATCH" unless ok
  end
end
