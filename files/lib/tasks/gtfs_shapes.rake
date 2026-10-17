# frozen_string_literal: true

namespace :gtfs do
  desc 'Use map-matched (pfaedle) shapes for a feed: gtfs:overlay_shapes[FEED_KEY,ZIP_PATH] ' \
       '(default path: GTFS_<KEY>_SHAPES_ZIP)'
  task :overlay_shapes, %i[feed_key zip_path] => :environment do |_, args|
    feed = Gtfs::Feed.find_by!(key: args[:feed_key])
    path = args[:zip_path].presence || Gtfs::ShapeOverlay.env_path_for(feed)
    abort "no zip given and GTFS_#{feed.key.upcase}_SHAPES_ZIP is not set" if path.blank?

    stats = Gtfs::ShapeOverlay.new(feed, path).call
    puts "#{feed.key} v#{feed.active_version}: #{stats.to_json}"
    puts 'Rematch the affected days (gtfs:rematch / POST /api/v1/transit/rematch) to use the new shapes.'
  end
end
