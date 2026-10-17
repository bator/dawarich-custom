# frozen_string_literal: true

# Map-matched shapes for feeds whose own shapes do not follow the track (the
# MÁV feed: straight or coarse lines, so rail rides are matched and drawn
# stop to stop). The source is a GTFS zip produced by pfaedle
# (https://github.com/ad-freiburg/pfaedle), e.g.
#
#   pfaedle -D -m rail -x hungary-latest.osm.pbf -o out/ mav.zip
#
# Only trips.txt, shapes.txt and (for the fallback) stop_times.txt are read.
# A trip of the feed version gets the pfaedle shape of
#   1. the trip with the same trip_id (pfaedle run on the same download), or
#   2. a trip with the same stop sequence (trip ids change between MÁV
#      downloads; the stop ids do not), when that pattern has one shape.
# Shapes are stored as extra gtfs_shapes rows ("pfaedle:<shape_id>") of the
# same feed version and the trips point to them. The matcher still checks
# every shape against the stops (TripProfile) and falls back to the stops
# when a shape does not fit, so a wrong overlay cannot make a match worse
# than without it. Points are never touched.
#
# Running it again on the same feed version replaces the earlier pfaedle
# shapes; trips that got no new one are left without a shape (the matcher
# then uses the stops) - the feed's own shapes come back only with the next
# import of the feed (review A3). The zip is streamed, never unpacked to
# disk, and must not be larger than GTFS_SHAPES_ZIP_MAX_BYTES (default 1 GB).
class Gtfs::ShapeOverlay
  PREFIX = 'pfaedle:'
  DEFAULT_MAX_BYTES = 1024 * 1024 * 1024

  class Error < StandardError; end

  def self.max_bytes
    Integer(ENV.fetch('GTFS_SHAPES_ZIP_MAX_BYTES', DEFAULT_MAX_BYTES), exception: false) || DEFAULT_MAX_BYTES
  end

  def self.env_path_for(feed)
    ENV["GTFS_#{feed.key.upcase}_SHAPES_ZIP"].presence
  end

  def initialize(feed, zip_path, version: feed.active_version, logger: Rails.logger)
    @feed = feed
    @zip_path = zip_path
    @version = version
    @logger = logger
    @stats = { 'source' => File.basename(zip_path.to_s) }
  end

  # => stats hash (trips, by_trip_id, by_pattern, shapes, ...)
  def call
    raise Error, "feed #{@feed.key} has no imported version" if @version.to_i.zero?
    raise Error, "#{@zip_path} not found" unless File.file?(@zip_path.to_s)
    if File.size(@zip_path.to_s) > self.class.max_bytes
      raise Error, "#{@zip_path} is larger than GTFS_SHAPES_ZIP_MAX_BYTES (#{self.class.max_bytes})"
    end

    targets = trip_patterns
    @stats['trips'] = targets.size
    mapping = nil
    Gtfs::ZipReader.open(@zip_path) do |zip|
      %w[trips.txt shapes.txt].each { |name| raise Error, "#{name} missing in #{@zip_path}" unless zip.file?(name) }
      mapping = assign_shapes(zip, targets)
      ActiveRecord::Base.transaction { write!(zip, mapping) }
    end
    @logger.info("[GTFS] shape overlay for #{@feed.key} v#{@version}: #{@stats.except('source').to_json}")
    @stats
  end

  private

  def binds
    { feed_id: Integer(@feed.id), version: Integer(@version) }
  end

  def conn
    ActiveRecord::Base.connection
  end

  # trip_id => stop pattern ("stopA>stopB>...") of the feed version
  def trip_patterns
    sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, binds])
      SELECT t.gtfs_id, string_agg(st.stop_gtfs_id, '>' ORDER BY st.stop_sequence)
      FROM gtfs_trips t
      JOIN gtfs_stop_times st ON st.feed_id = t.feed_id AND st.version = t.version AND st.trip_gtfs_id = t.gtfs_id
      WHERE t.feed_id = :feed_id AND t.version = :version
      GROUP BY t.gtfs_id
    SQL
    conn.select_rows(sql).to_h
  end

  # trip_id => overlay shape_id
  def assign_shapes(zip, targets)
    overlay_shape = {}
    zip.each_row('trips.txt', required: %w[trip_id]) do |row|
      overlay_shape[row['trip_id']] = row['shape_id'] if row['trip_id'] && row['shape_id'].present?
    end

    mapping = {}
    targets.each_key { |trip_id| mapping[trip_id] = overlay_shape[trip_id] if overlay_shape[trip_id] }
    @stats['by_trip_id'] = mapping.size

    missing = targets.except(*mapping.keys)
    by_pattern = missing.empty? || !zip.file?('stop_times.txt') ? {} : pattern_shapes(zip, overlay_shape)
    missing.each do |trip_id, pattern|
      shape = by_pattern[pattern]
      mapping[trip_id] = shape if shape
    end
    @stats['by_pattern'] = mapping.size - @stats['by_trip_id']
    @stats['unmatched'] = targets.size - mapping.size
    mapping
  end

  # stop pattern => shape_id, only for patterns that all overlay trips share
  # one shape for (otherwise ambiguous: no shape)
  def pattern_shapes(zip, overlay_shape)
    stops = Hash.new { |h, k| h[k] = [] }
    zip.each_row('stop_times.txt', required: %w[trip_id stop_id stop_sequence]) do |row|
      next unless overlay_shape.key?(row['trip_id'])

      stops[row['trip_id']] << [row['stop_sequence'].to_i, row['stop_id']]
    end
    shapes = Hash.new { |h, k| h[k] = Set.new }
    stops.each do |trip_id, list|
      shapes[list.sort_by!(&:first).map(&:last).join('>')] << overlay_shape[trip_id]
    end
    shapes.filter_map { |pattern, ids| [pattern, ids.first] if ids.size == 1 }.to_h
  end

  def write!(zip, mapping)
    needed = mapping.values.to_set
    conn.execute('DROP TABLE IF EXISTS pg_temp.gtfs_tmp_overlay_points')
    conn.execute('CREATE TEMP TABLE gtfs_tmp_overlay_points (shape_id text, seq double precision, ' \
                 'lon double precision, lat double precision)')
    Gtfs::CopyWriter.copy('gtfs_tmp_overlay_points', %w[shape_id seq lon lat]) do |out|
      zip.each_row('shapes.txt', required: %w[shape_id shape_pt_lat shape_pt_lon shape_pt_sequence]) do |row|
        next unless needed.include?(row['shape_id'])

        lat = Float(row['shape_pt_lat'], exception: false)
        lon = Float(row['shape_pt_lon'], exception: false)
        seq = Float(row['shape_pt_sequence'], exception: false)
        out.call([row['shape_id'], seq, lon, lat]) if lat && lon && seq
      end
    end

    conn.execute(ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, binds.merge(like: "#{PREFIX}%")]))
      UPDATE gtfs_trips t SET shape_gtfs_id = NULL
      WHERE t.feed_id = :feed_id AND t.version = :version AND t.shape_gtfs_id LIKE :like
    SQL
    conn.execute(ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, binds.merge(like: "#{PREFIX}%")]))
      DELETE FROM gtfs_shapes WHERE feed_id = :feed_id AND version = :version AND gtfs_id LIKE :like
    SQL
    conn.execute(ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, binds.merge(prefix: PREFIX)]))
      INSERT INTO gtfs_shapes (feed_id, version, gtfs_id, path, length_m)
      SELECT :feed_id, :version, :prefix || shape_id, line, ST_Length(line)
      FROM (
        SELECT shape_id,
               ST_MakeLine(ST_SetSRID(ST_MakePoint(lon, lat), 4326) ORDER BY seq)::geography AS line,
               count(*) AS n
        FROM gtfs_tmp_overlay_points GROUP BY shape_id
      ) s
      WHERE n >= 2
    SQL
    @stats['shapes'] =
      Gtfs::Shape.where(feed_id: @feed.id, version: @version).where('gtfs_id LIKE ?', "#{PREFIX}%").count
    @stats['points'] = conn.select_value('SELECT count(*) FROM gtfs_tmp_overlay_points').to_i
    update_trips!(mapping)
  ensure
    conn.execute('DROP TABLE IF EXISTS pg_temp.gtfs_tmp_overlay_points')
  end

  # Original shape ids are kept nowhere else, so trips whose overlay shape is
  # missing (fewer than 2 points) keep their own shape.
  def update_trips!(mapping)
    conn.execute('DROP TABLE IF EXISTS pg_temp.gtfs_tmp_overlay_trips')
    conn.execute('CREATE TEMP TABLE gtfs_tmp_overlay_trips (trip_id text, shape_id text)')
    Gtfs::CopyWriter.copy('gtfs_tmp_overlay_trips', %w[trip_id shape_id]) do |out|
      mapping.each { |trip_id, shape_id| out.call([trip_id, PREFIX + shape_id]) }
    end
    conn.execute('ANALYZE gtfs_tmp_overlay_trips') # temp tables are never auto-analyzed
    @stats['trips_updated'] = conn.update(ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, binds]))
      UPDATE gtfs_trips t SET shape_gtfs_id = m.shape_id
      FROM gtfs_tmp_overlay_trips m
      WHERE t.feed_id = :feed_id AND t.version = :version AND t.gtfs_id = m.trip_id
        AND EXISTS (SELECT 1 FROM gtfs_shapes s
                    WHERE s.feed_id = :feed_id AND s.version = :version AND s.gtfs_id = m.shape_id)
    SQL
  ensure
    conn.execute('DROP TABLE IF EXISTS pg_temp.gtfs_tmp_overlay_trips')
  end
end
