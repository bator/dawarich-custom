# frozen_string_literal: true

# Deletes the rows of one (feed, version) from every GTFS data table in small
# batches so that long locks are avoided (spec 7.4/6, 10).
class Gtfs::VersionPurger
  TABLES = %w[gtfs_stop_times gtfs_shapes gtfs_trips gtfs_service_days gtfs_frequencies gtfs_routes gtfs_stops].freeze
  BATCH_SIZE = ENV.fetch('GTFS_DELETE_BATCH_SIZE', 50_000).to_i

  # Retention rule (decision K4): per feed exactly ONE backup is kept, i.e.
  # the active version and the newest version below it (the previously
  # active one). Everything else is removed. Callers must hold the feed's
  # advisory lock. Returns the purged version numbers.
  def self.retain_active_and_backup!(feed_id, active_version)
    existing = versions(feed_id)
    backup = existing.select { |v| v < active_version }.max
    stale = existing - [active_version, backup].compact
    stale.each { |version| purge!(feed_id, version) }
    stale
  end

  def self.purge!(feed_id, version)
    TABLES.sum { |table| purge_table!(table, Integer(feed_id), Integer(version)) }
  end

  # Versions that exist in the data tables for a feed.
  def self.versions(feed_id)
    TABLES.flat_map do |table|
      ActiveRecord::Base.connection.select_values(
        ActiveRecord::Base.sanitize_sql_array(["SELECT DISTINCT version FROM #{table} WHERE feed_id = ?", feed_id])
      )
    end.uniq.sort
  end

  def self.purge_table!(table, feed_id, version)
    deleted = 0
    loop do
      sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, feed_id, version, BATCH_SIZE])
        DELETE FROM #{table} WHERE ctid = ANY(ARRAY(
          SELECT ctid FROM #{table} WHERE feed_id = ? AND version = ? LIMIT ?
        ))
      SQL
      count = ActiveRecord::Base.connection.exec_delete(sql, 'Gtfs purge')
      deleted += count
      break if count < BATCH_SIZE
    end
    deleted
  end
end
