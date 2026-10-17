# frozen_string_literal: true

require 'digest'

# Streams a GTFS zip into the gtfs_* tables under a new version and only then
# switches gtfs_feeds.active_version (blue/green, spec 6 and 7.4). A failed
# import leaves the previously active version untouched.
#
# Usage: Gtfs::FeedImporter.new(feed, '/path/gtfs.zip').call
class Gtfs::FeedImporter
  class ImportError < StandardError; end
  class AlreadyRunning < StandardError; end

  REQUIRED_FILES = %w[agency.txt stops.txt routes.txt trips.txt stop_times.txt].freeze
  MAX_BAD_ROW_RATIO = ENV.fetch('GTFS_MAX_BAD_ROW_RATIO', 0.01).to_f
  MIN_RESOLVED_RATIO = 0.995
  DATA_TABLES = Gtfs::VersionPurger::TABLES
  ANALYZE_STATEMENTS = DATA_TABLES.map { |table| "ANALYZE #{table}" }.freeze
  WEEKDAYS = Gtfs::ServiceCalendar::WEEKDAYS
  COPY_ESCAPES = {
    't' => "\t", 'n' => "\n", 'r' => "\r", 'b' => "\b", 'f' => "\f", 'v' => "\v", '\\' => '\\'
  }.freeze

  Result = Struct.new(:status, :version, :stats, keyword_init: true)

  attr_reader :stats

  # etag / last_modified: HTTP cache validators of the downloaded zip. They are
  # only stored together with a successful import (or an :unchanged result), so
  # a failed import is downloaded again next time instead of getting a 304.
  def initialize(feed, zip_path, force: false, sha256: nil, etag: nil, last_modified: nil,
                 today: Date.current, logger: Rails.logger)
    @feed = feed
    @zip_path = zip_path.to_s
    @force = force
    @sha256 = sha256
    @http_validators = { etag:, last_modified_remote: last_modified }
    @today = today
    @logger = logger
    @stats = { 'files' => {}, 'timings' => {} }
  end

  def call
    lock = ActiveRecord::Base.with_advisory_lock_result(@feed.advisory_lock_name, timeout_seconds: 0) { import! }
    raise AlreadyRunning, "an import of feed #{@feed.key} is already running" unless lock.lock_was_acquired?

    lock.result
  end

  private

  def import!
    # The caller may have loaded the feed minutes ago (before a long download);
    # another process may have imported it since. Only trust fresh state that
    # was read while holding the lock.
    @feed.reload
    sha = @sha256 || Digest::SHA256.file(@zip_path).hexdigest
    if !@force && @feed.imported? && @feed.content_sha256 == sha
      recover_interrupted_import! if @feed.importing?
      @feed.update!(last_checked_at: Time.current, status: :idle, last_error: nil, **http_validators)
      log("unchanged (sha256 #{sha[0, 12]}), skipping import")
      return Result.new(status: :unchanged, version: @feed.active_version, stats: {})
    end

    recover_interrupted_import! if @feed.importing?
    purge_stale_versions!
    @base_version = @feed.active_version
    @version = @base_version + 1
    @feed.update!(status: :importing, last_error: nil)
    started = monotonic
    feed_window = nil
    timezone = nil

    Gtfs::ZipReader.open(@zip_path) do |zip|
      @zip = zip
      check_required_files!
      timezone = timed('agency') { import_agency }
      feed_window = timed('feed_info') { import_feed_info }
      timed('stops') { import_stops }
      timed('routes') { import_routes }
      timed('calendar') { import_calendar(feed_window) }
      if @feed.import_shapes && zip.file?('shapes.txt')
        timed('shapes') { import_shapes }
      else
        @stats['shapes_skipped'] = true
      end
      timed('trips') { import_trips }
      timed('stop_times') { import_stop_times }
      timed('frequencies') { import_frequencies } if zip.file?('frequencies.txt')
      @stats['placeholders_ignored'] = zip.placeholder_count
      record_encoding_stats(zip)
    end

    timed('shape_overlay') { apply_shape_overlay }
    timed('integrity') { check_integrity! }
    timed('analyze') { analyze_tables }
    valid_from, valid_until = validity(feed_window)
    @stats['total_secs'] = (monotonic - started).round(1)
    @stats['max_rss_mb'] = max_rss_mb
    @stats['sha256'] = sha

    activate_version!(sha:, valid_from:, valid_until:, timezone:)
    log("imported version #{@version} in #{@stats['total_secs']}s: #{summary}")
    enqueue_rematch
    rotate_backup!
    Result.new(status: :imported, version: @version, stats: @stats)
  rescue ImportError, Gtfs::ZipReader::Error => e
    fail_import!(e)
    raise
  rescue StandardError => e
    # Anything unexpected (PG error, I/O, corrupt zip stream): the partial
    # version is gone and the feed is marked failed, so retrying the same zip
    # would not help. Re-raise as ImportError (cause is kept).
    fail_import!(e)
    raise ImportError, "#{e.class}: #{e.message}"
  end

  # Map-matched shapes (pfaedle, Gtfs::ShapeOverlay) for feeds whose own
  # shapes do not follow the track (GTFS_<KEY>_SHAPES_ZIP), applied to the new
  # version before it becomes active. A failure is recorded in the stats and
  # never fails the import: the trips keep their own shapes.
  def apply_shape_overlay
    path = Gtfs::ShapeOverlay.env_path_for(@feed)
    return unless path

    # The overlay joins gtfs_trips/gtfs_stop_times of the new version, which the
    # planner statistics do not know yet (they are refreshed after the import).
    # On a re-import that made Postgres pick a nested loop that did not finish
    # in 15 minutes on the MÁV feed (live, 2026-10-10); with fresh statistics
    # the same overlay takes about 3 minutes.
    timed('analyze_before_overlay') { analyze_tables }
    @stats['shape_overlay'] = Gtfs::ShapeOverlay.new(@feed, path, version: @version).call
  rescue StandardError => e
    @stats['shape_overlay'] = { 'error' => "#{e.class}: #{e.message}".truncate(300) }
    log("shape overlay failed (#{e.class}: #{e.message}); keeping the feed's own shapes")
  end

  # Version flip under a row lock, re-checking that nobody switched the feed in
  # the meantime (defence in depth on top of the advisory lock).
  def activate_version!(sha:, valid_from:, valid_until:, timezone:)
    Gtfs::Feed.transaction do
      current = Gtfs::Feed.lock.find(@feed.id)
      if current.active_version != @base_version
        raise ImportError, "feed #{@feed.key} was switched to version #{current.active_version} during the import " \
                           "(expected #{@base_version})"
      end

      current.update!(
        active_version: @version, status: :idle, last_error: nil, last_imported_at: Time.current,
        last_checked_at: Time.current, content_sha256: sha, valid_from:, valid_until:,
        timezone: timezone || current.timezone, import_stats: @stats, **http_validators
      )
      @feed = current
    end
  end

  # Phase 2 (spec 9.10): the new timetable may change recent `auto` matches.
  # Enqueued right after the switch, before the backup rotation (review A10);
  # an enqueue error must not turn the committed import into a failure.
  def enqueue_rematch
    Gtfs::RematchAfterImportJob.perform_later(@feed.id)
  rescue StandardError => e
    log("could not enqueue the rematch (#{e.class}: #{e.message}); the daily match job covers recent days")
  end

  # Decision K4: after a successful switch the previously active version is
  # the single backup and anything older goes, right away and still under the
  # feed lock. Never called for a failed import. A purge error does not undo
  # the (already committed) import; the cleanup job retries it.
  def rotate_backup!
    purged = Gtfs::VersionPurger.retain_active_and_backup!(@feed.id, @version)
    log("removed old version(s) #{purged.join(', ')}; backup is version #{@base_version}") if purged.any?
  rescue StandardError => e
    log("could not remove old versions (#{e.class}: #{e.message}); cleanup job enqueued")
    Gtfs::CleanupOldVersionsJob.perform_later(@feed.id)
  end

  def http_validators
    @http_validators.compact
  end

  # ---- files ---------------------------------------------------------------

  def check_required_files!
    missing = REQUIRED_FILES.reject { |f| @zip.file?(f) }
    unless @zip.file?('calendar.txt') || @zip.file?('calendar_dates.txt')
      missing << 'calendar.txt or calendar_dates.txt'
    end
    raise ImportError, "missing required GTFS file(s): #{missing.join(', ')}" if missing.any?
  end

  def import_agency
    timezones = []
    count = each_row('agency.txt', required: %w[agency_timezone]) do |row, file|
      tz = row['agency_timezone']
      if tz && ActiveSupport::TimeZone[tz]
        timezones << tz
      else
        file.bad!("unknown agency_timezone #{tz.inspect}")
      end
    end
    timezones.uniq!
    @stats['agencies'] = count
    if timezones.size > 1
      @stats['warnings'] =
        (@stats['warnings'] || []) << "multiple agency timezones: #{timezones.join(', ')}"
    end
    timezones.first
  end

  def import_feed_info
    return nil unless @zip.file?('feed_info.txt')

    window = nil
    each_row('feed_info.txt') do |row, _file|
      next if window

      from = parse_date(row['feed_start_date'])
      to = parse_date(row['feed_end_date'])
      @stats['feed_version'] = row['feed_version']
      window = from || to ? (from..to) : nil
    end
    if window&.begin && window.end && window.begin > window.end
      (@stats['warnings'] ||= []) << "feed_info window #{window.begin}..#{window.end} is inverted, ignored"
      window = nil
    end
    window
  end

  def import_stops
    seen = Set.new
    @stop_coords = {}
    copy('gtfs_stops',
         %w[feed_id version gtfs_id name location_type parent_station_gtfs_id platform_code lonlat]) do |out|
      each_row('stops.txt', required: %w[stop_id]) do |row, file|
        id = row['stop_id']
        next file.bad!('blank stop_id') if id.nil?
        next file.bad!("duplicate stop_id #{id}") unless seen.add?(id)

        lat = parse_float(row['stop_lat'])
        lon = parse_float(row['stop_lon'])
        location_type = parse_int(row['location_type']) || 0
        unless lat && lon && lat.between?(-90, 90) && lon.between?(-180, 180) && !(lat.zero? && lon.zero?)
          # Generic nodes / boarding areas (3, 4) may legally omit coordinates.
          location_type >= 3 ? file.skip! : file.bad!("stop #{id} without valid coordinates")
          next
        end

        @stop_coords[id] = [lat, lon]
        out.call([@feed.id, @version, id, row['stop_name'] || '', location_type, row['parent_station'],
                  row['platform_code'], "SRID=4326;POINT(#{lon} #{lat})"])
      end
    end
  end

  def import_routes
    seen = Set.new
    copy('gtfs_routes',
         %w[feed_id version gtfs_id agency_gtfs_id short_name long_name route_type color text_color]) do |out|
      each_row('routes.txt', required: %w[route_id route_type]) do |row, file|
        id = row['route_id']
        type = parse_int(row['route_type'])
        next file.bad!('blank route_id') if id.nil?
        next file.bad!("route #{id}: invalid route_type #{row['route_type'].inspect}") if type.nil?
        next file.bad!("duplicate route_id #{id}") unless seen.add?(id)

        out.call([@feed.id, @version, id, row['agency_id'], row['route_short_name'], row['route_long_name'], type,
                  row['route_color'], row['route_text_color']])
      end
    end
  end

  def import_calendar(feed_window)
    calendar_rows = []
    if @zip.file?('calendar.txt')
      each_row('calendar.txt', required: %w[service_id start_date end_date] + WEEKDAYS) do |row, file|
        start_date = parse_date(row['start_date'])
        end_date = parse_date(row['end_date'])
        if row['service_id'].nil? || start_date.nil? || end_date.nil?
          next file.bad!("calendar #{row['service_id']}: invalid dates")
        end

        calendar_rows << { service_id: row['service_id'], start_date:, end_date:,
                           days: WEEKDAYS.map { |d| row[d] == '1' } }
      end
    end

    date_rows = []
    if @zip.file?('calendar_dates.txt')
      each_row('calendar_dates.txt', required: %w[service_id date exception_type]) do |row, file|
        date = parse_date(row['date'])
        type = parse_int(row['exception_type'])
        next file.bad!('invalid calendar_dates row') if row['service_id'].nil? || date.nil? || ![1, 2].include?(type)

        date_rows << { service_id: row['service_id'], date:, exception_type: type }
      end
    end

    services = Gtfs::ServiceCalendar.expand(calendar_rows:, date_rows:, window: feed_window, today: @today)
    days = copy('gtfs_service_days', %w[feed_id version service_gtfs_id service_date]) do |out|
      services.each do |service_id, dates|
        dates.each { |date| out.call([@feed.id, @version, service_id, date.iso8601]) }
      end
    end
    @stats['service_ids'] = services.size
    @stats['service_days'] = days
  end

  def import_shapes
    conn = ActiveRecord::Base.connection
    conn.execute('DROP TABLE IF EXISTS pg_temp.gtfs_tmp_shape_points')
    conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE gtfs_tmp_shape_points
        (shape_id text, seq double precision, lon double precision, lat double precision)
    SQL
    copy('gtfs_tmp_shape_points', %w[shape_id seq lon lat]) do |out|
      each_row('shapes.txt', required: %w[shape_id shape_pt_lat shape_pt_lon shape_pt_sequence]) do |row, file|
        lat = parse_float(row['shape_pt_lat'])
        lon = parse_float(row['shape_pt_lon'])
        seq = parse_float(row['shape_pt_sequence'])
        next file.bad!('invalid shape point') if row['shape_id'].nil? || lat.nil? || lon.nil? || seq.nil?

        out.call([row['shape_id'], seq, lon, lat])
      end
    end
    # Points are ordered numerically by shape_pt_sequence (10 after 2).
    conn.execute(sanitize([<<~SQL.squish, version_binds]))
      INSERT INTO gtfs_shapes (feed_id, version, gtfs_id, path, length_m)
      SELECT :feed_id, :version, shape_id, line, ST_Length(line)
      FROM (
        SELECT shape_id,
               ST_MakeLine(ST_SetSRID(ST_MakePoint(lon, lat), 4326) ORDER BY seq)::geography AS line,
               count(*) AS n
        FROM gtfs_tmp_shape_points GROUP BY shape_id
      ) s
      WHERE n >= 2
    SQL
    total = conn.select_value('SELECT count(DISTINCT shape_id) FROM gtfs_tmp_shape_points').to_i
    @stats['shapes'] = Gtfs::Shape.where(feed_id: @feed.id, version: @version).count
    @stats['shapes_dropped_single_point'] = total - @stats['shapes']
  ensure
    ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS pg_temp.gtfs_tmp_shape_points')
  end

  def import_trips
    seen = Set.new
    copy('gtfs_trips',
         %w[feed_id version gtfs_id route_gtfs_id service_gtfs_id headsign short_name direction_id
            shape_gtfs_id]) do |out|
      each_row('trips.txt', required: %w[route_id service_id trip_id]) do |row, file|
        id = row['trip_id']
        if id.nil? || row['route_id'].nil? || row['service_id'].nil?
          next file.bad!('trip without trip_id/route_id/service_id')
        end
        next file.bad!("duplicate trip_id #{id}") unless seen.add?(id)

        out.call([@feed.id, @version, id, row['route_id'], row['service_id'], row['trip_headsign'],
                  row['trip_short_name'], parse_int(row['direction_id']), row['shape_id']])
      end
    end
  end

  def import_stop_times
    conn = ActiveRecord::Base.connection
    conn.execute('DROP TABLE IF EXISTS pg_temp.gtfs_tmp_stop_times')
    conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE gtfs_tmp_stop_times
        (trip_id text, seq integer, stop_id text, arr integer, dep integer, dist double precision)
    SQL
    copy('gtfs_tmp_stop_times', %w[trip_id seq stop_id arr dep dist]) do |out|
      each_row('stop_times.txt', required: %w[trip_id stop_id stop_sequence]) do |row, file|
        seq = parse_int(row['stop_sequence'])
        if row['trip_id'].nil? || row['stop_id'].nil? || seq.nil?
          next file.bad!('stop_time without trip_id/stop_id/stop_sequence')
        end

        begin
          arr = Gtfs::TimeParser.parse(row['arrival_time'])
          dep = Gtfs::TimeParser.parse(row['departure_time'])
        rescue Gtfs::TimeParser::InvalidTime => e
          next file.bad!(e.message)
        end
        out.call([row['trip_id'], seq, row['stop_id'], arr, dep, parse_float(row['shape_dist_traveled'])])
      end
    end

    sorted = Tempfile.new(['gtfs-stop-times', '.tsv'], Gtfs.tmp_dir, binmode: true)
    raw = conn.raw_connection
    sorted_sql = 'COPY (SELECT trip_id, seq, stop_id, arr, dep, dist FROM gtfs_tmp_stop_times ' \
                 'ORDER BY trip_id, seq) TO STDOUT'
    raw.copy_data(sorted_sql) do
      while (chunk = raw.get_copy_data)
        sorted.write(chunk)
      end
    end
    conn.execute('DROP TABLE IF EXISTS pg_temp.gtfs_tmp_stop_times')
    sorted.flush
    sorted.rewind

    summaries = []
    counters = Hash.new(0)
    copy('gtfs_stop_times',
         %w[feed_id version trip_gtfs_id stop_gtfs_id stop_sequence arrival_secs departure_secs interpolated]) do |out|
      each_sorted_trip(sorted, counters) do |trip_id, rows|
        result = Gtfs::StopTimeInterpolator.call(rows, @stop_coords)
        counters['interpolated'] += result.interpolated_count
        counters['invalid_trips'] += 1 unless result.valid
        result.rows.each do |r|
          out.call([@feed.id, @version, trip_id, r[:stop_id], r[:stop_sequence], r[:arrival_secs], r[:departure_secs],
                    r[:interpolated]])
        end
        summaries << [trip_id, result.first_departure_secs, result.last_arrival_secs, result.valid]
      end
    end
    @stats['stop_times_interpolated'] = counters['interpolated']
    @stats['stop_times_duplicate_sequence'] = counters['duplicate_sequence']
    @stats['trips_invalid_times'] = counters['invalid_trips']
    update_trip_summaries(summaries)
  ensure
    sorted&.close!
    ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS pg_temp.gtfs_tmp_stop_times')
  end

  def each_sorted_trip(io, counters)
    current = nil
    rows = []
    io.each_line do |line|
      trip_id, seq, stop_id, arr, dep, dist = line.chomp.split("\t", -1).map { |v| decode_copy(v) }
      seq = seq.to_i
      if trip_id != current
        yield current, rows if current
        current = trip_id
        rows = []
      elsif rows.last && rows.last[:stop_sequence] == seq
        counters['duplicate_sequence'] += 1
        next
      end
      rows << { stop_id:, stop_sequence: seq, arrival_secs: arr&.to_i, departure_secs: dep&.to_i, dist: dist&.to_f }
    end
    yield current, rows if current
  end

  def update_trip_summaries(summaries)
    conn = ActiveRecord::Base.connection
    conn.execute('DROP TABLE IF EXISTS pg_temp.gtfs_tmp_trip_summary')
    conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE gtfs_tmp_trip_summary
        (trip_id text, first_dep integer, last_arr integer, valid boolean)
    SQL
    copy('gtfs_tmp_trip_summary', %w[trip_id first_dep last_arr valid]) do |out|
      summaries.each { |s| out.call(s) }
    end
    conn.execute(sanitize([<<~SQL.squish, version_binds]))
      UPDATE gtfs_trips t
         SET first_departure_secs = s.first_dep, last_arrival_secs = s.last_arr, times_valid = s.valid
        FROM pg_temp.gtfs_tmp_trip_summary s
       WHERE t.feed_id = :feed_id AND t.version = :version AND t.gtfs_id = s.trip_id
    SQL
    # Trips without any stop_times can never be matched.
    conn.execute(sanitize([<<~SQL.squish, version_binds]))
      UPDATE gtfs_trips t SET times_valid = false
       WHERE t.feed_id = :feed_id AND t.version = :version AND t.first_departure_secs IS NULL
    SQL
  ensure
    ActiveRecord::Base.connection.execute('DROP TABLE IF EXISTS pg_temp.gtfs_tmp_trip_summary')
  end

  def import_frequencies
    copy('gtfs_frequencies', %w[feed_id version trip_gtfs_id start_secs end_secs headway_secs exact_times]) do |out|
      each_row('frequencies.txt', required: %w[trip_id start_time end_time headway_secs]) do |row, file|
        begin
          start_secs = Gtfs::TimeParser.parse(row['start_time'])
          end_secs = Gtfs::TimeParser.parse(row['end_time'])
        rescue Gtfs::TimeParser::InvalidTime => e
          next file.bad!(e.message)
        end
        headway = parse_int(row['headway_secs'])
        if row['trip_id'].nil? || start_secs.nil? || end_secs.nil? || headway.nil? || headway <= 0
          next file.bad!('invalid frequencies row')
        end

        out.call([@feed.id, @version, row['trip_id'], start_secs, end_secs, headway,
                  parse_int(row['exact_times']) || 0])
      end
    end
  end

  # ---- checks ----------------------------------------------------------------

  def check_integrity!
    counts = DATA_TABLES.index_with do |table|
      ActiveRecord::Base.connection.select_value(
        sanitize(["SELECT count(*) FROM #{quote_table(table)} WHERE feed_id = :feed_id AND version = :version",
                  version_binds])
      ).to_i
    end
    @stats['rows'] = counts
    %w[gtfs_stops gtfs_routes gtfs_trips gtfs_service_days].each do |table|
      raise ImportError, "integrity check failed: no rows in #{table}" if counts[table].zero?
    end

    unresolved = ActiveRecord::Base.connection.select_value(sanitize([<<~SQL.squish, version_binds])).to_i
      SELECT count(*) FROM gtfs_stop_times st
      WHERE st.feed_id = :feed_id AND st.version = :version
        AND (NOT EXISTS (SELECT 1 FROM gtfs_trips t WHERE t.feed_id = st.feed_id AND t.version = st.version AND t.gtfs_id = st.trip_gtfs_id)
          OR NOT EXISTS (SELECT 1 FROM gtfs_stops s WHERE s.feed_id = st.feed_id AND s.version = st.version AND s.gtfs_id = st.stop_gtfs_id))
    SQL
    total = counts['gtfs_stop_times']
    @stats['stop_times_unresolved'] = unresolved
    ratio = total.zero? ? 0.0 : (total - unresolved).fdiv(total)
    raise ImportError, 'integrity check failed: no stop_times' if total.zero?
    if ratio < MIN_RESOLVED_RATIO
      raise ImportError,
            format('integrity check failed: only %.2f%% of stop_times reference known trips and stops', ratio * 100)
    end

    check_trip_references!(counts['gtfs_trips'])
  end

  # trips -> routes must resolve (threshold); trips without service days and
  # unknown parent stations are only recorded (they occur in valid feeds, e.g.
  # services that ran only before the expansion window).
  def check_trip_references!(trip_count)
    conn = ActiveRecord::Base.connection
    no_route = conn.select_value(sanitize([<<~SQL.squish, version_binds])).to_i
      SELECT count(*) FROM gtfs_trips t
      WHERE t.feed_id = :feed_id AND t.version = :version
        AND NOT EXISTS (SELECT 1 FROM gtfs_routes r
                        WHERE r.feed_id = t.feed_id AND r.version = t.version AND r.gtfs_id = t.route_gtfs_id)
    SQL
    no_service = conn.select_value(sanitize([<<~SQL.squish, version_binds])).to_i
      SELECT count(*) FROM gtfs_trips t
      WHERE t.feed_id = :feed_id AND t.version = :version
        AND NOT EXISTS (SELECT 1 FROM gtfs_service_days d
                        WHERE d.feed_id = t.feed_id AND d.version = t.version AND d.service_gtfs_id = t.service_gtfs_id)
    SQL
    no_parent = conn.select_value(sanitize([<<~SQL.squish, version_binds])).to_i
      SELECT count(*) FROM gtfs_stops s
      WHERE s.feed_id = :feed_id AND s.version = :version AND s.parent_station_gtfs_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM gtfs_stops p
                        WHERE p.feed_id = s.feed_id AND p.version = s.version AND p.gtfs_id = s.parent_station_gtfs_id)
    SQL
    @stats['trips_unknown_route'] = no_route
    @stats['trips_without_service_days'] = no_service
    @stats['stops_unknown_parent_station'] = no_parent
    ratio = trip_count.zero? ? 1.0 : (trip_count - no_route).fdiv(trip_count)
    return if ratio >= MIN_RESOLVED_RATIO

    raise ImportError, format('integrity check failed: only %.2f%% of trips reference known routes', ratio * 100)
  end

  def analyze_tables
    ANALYZE_STATEMENTS.each { |sql| ActiveRecord::Base.connection.execute(sql) }
  end

  def version_binds
    { feed_id: Integer(@feed.id), version: Integer(@version) }
  end

  def sanitize(args)
    ActiveRecord::Base.sanitize_sql_array(args)
  end

  def quote_table(table)
    raise ArgumentError, "unexpected table #{table}" unless DATA_TABLES.include?(table)

    ActiveRecord::Base.connection.quote_table_name(table)
  end

  def validity(feed_window)
    from = feed_window&.begin
    to = feed_window&.end
    if from.nil? || to.nil?
      range = Gtfs::ServiceDay.where(feed_id: @feed.id, version: @version).pick(Arel.sql('min(service_date)'),
                                                                                Arel.sql('max(service_date)'))
      from ||= range&.first
      to ||= range&.last
    end
    [from, to]
  end

  # ---- helpers ---------------------------------------------------------------

  FileStats = Struct.new(:name, :rows, :bad, :skipped, :samples) do
    def bad!(message)
      self.bad += 1
      samples << message if samples.size < 5
      nil
    end

    def skip!
      self.skipped += 1
      nil
    end
  end

  def each_row(name, required: [])
    file = FileStats.new(name, 0, 0, 0, [])
    file.rows = @zip.each_row(name, required:) { |row| yield row, file }
    @stats['files'][name] =
      { 'rows' => file.rows, 'bad' => file.bad, 'skipped' => file.skipped, 'samples' => file.samples }
    if file.rows.positive? && file.bad.fdiv(file.rows) > MAX_BAD_ROW_RATIO
      raise ImportError, "#{name}: #{file.bad} of #{file.rows} rows are invalid (e.g. #{file.samples.first})"
    end

    file.rows
  end

  def copy(table, columns, &)
    Gtfs::CopyWriter.copy(table, columns, &)
  end

  def decode_copy(value)
    return nil if value == '\N'
    return value unless value.include?('\\')

    value.gsub(/\\(.)/) do
      COPY_ESCAPES.fetch(::Regexp.last_match(1), ::Regexp.last_match(1))
    end
  end

  def parse_date(value)
    return nil if value.nil?

    Date.strptime(value, '%Y%m%d')
  rescue Date::Error
    nil
  end

  def parse_int(value)
    Integer(value, 10, exception: false) if value
  end

  def parse_float(value)
    Float(value, exception: false) if value
  end

  # Only called with the advisory lock held and a freshly reloaded feed, so
  # every version above active_version is a leftover of an interrupted import
  # (never the version another process just activated).
  def purge_stale_versions!
    Gtfs::VersionPurger.versions(@feed.id).select { |v| v > @feed.active_version }.each do |v|
      log("purging leftover version #{v} of an interrupted import")
      Gtfs::VersionPurger.purge!(@feed.id, v)
    end
  end

  # status=importing while we hold the lock means the previous import process
  # died (OOM, SIGKILL, deploy) without reaching its rescue block.
  def recover_interrupted_import!
    log('previous import was interrupted (status importing, lock free); cleaning up')
    @stats['recovered_interrupted_import'] = true
    purge_stale_versions!
    @feed.update!(status: :idle)
  end

  def fail_import!(error)
    begin
      # Never purge the active version: only the one this run was writing.
      Gtfs::VersionPurger.purge!(@feed.id, @version) if @version && @version != @feed.reload.active_version
    rescue StandardError => e
      log("could not purge partial version #{@version}: #{e.message}")
    end
    @feed.update_columns(status: Gtfs::Feed.statuses[:failed],
                         last_error: "#{error.class}: #{error.message}".truncate(2000),
                         updated_at: Time.current)
    log("import failed: #{error.class}: #{error.message}")
  end

  # K3: lines that were not valid UTF-8 are re-read as Windows-1250 (the
  # usual legacy encoding of Hungarian feeds); bytes that still cannot be
  # decoded are dropped and counted. Both are reported, never silent.
  def record_encoding_stats(zip)
    @stats['encoding'] = { 'legacy_lines' => zip.legacy_lines, 'dropped_bytes' => zip.dropped_bytes }
    return if zip.legacy_lines.zero? && zip.dropped_bytes.zero?

    warning = "non-UTF-8 input: #{zip.legacy_lines} line(s) decoded as Windows-1250, " \
              "#{zip.dropped_bytes} undecodable byte(s) dropped"
    (@stats['warnings'] ||= []) << warning
    log(warning)
  end

  def timed(phase)
    started = monotonic
    result = yield
    @stats['timings'][phase] = (monotonic - started).round(2)
    result
  end

  def summary
    (@stats['rows'] || {}).map { |t, c| "#{t.delete_prefix('gtfs_')}=#{c}" }.join(' ')
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def max_rss_mb
    line = File.foreach('/proc/self/status').find { |l| l.start_with?('VmHWM:') }
    line ? (line.split[1].to_i / 1024.0).round(1) : nil
  rescue StandardError
    nil
  end

  def log(message)
    @logger.info("[GTFS #{@feed.key}] #{message}")
  end
end
