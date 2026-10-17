# frozen_string_literal: true

# Static GTFS timetable storage (docs/gtfs.md). Every table is scoped by
# (feed_id, version): a re-import writes a new version and only flips
# gtfs_feeds.active_version at the end (blue/green), so readers never see a
# half-imported feed. *_gtfs_id columns are plain strings on purpose (no FKs):
# GTFS ids are only unique inside one feed and the importer checks integrity.
# Data is loaded by Gtfs::FeedImporter, never by this migration.
# GTFS data tables are bulk-loaded with COPY and replaced per version, so they
# deliberately have no created_at/updated_at (spec section 6 only had them on stops/routes/trips); gtfs_feeds has them.
# rubocop:disable Rails/CreateTableWithTimestamps
class CreateGtfsTables < ActiveRecord::Migration[8.1]
  # Review H4: never queue for a lock or run long (see docs/gtfs-deploy.md).
  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '5min'")
    super
  end

  def change
    create_table :gtfs_feeds do |t|
      t.string   :key,            null: false
      t.string   :name,           null: false
      t.string   :source_url
      t.string   :attribution
      t.string   :license_url
      t.string   :timezone,       null: false, default: 'Europe/Budapest'
      t.boolean  :enabled,        null: false, default: false
      t.boolean  :import_shapes,  null: false, default: true
      t.string   :etag
      t.datetime :last_modified_remote
      t.string   :content_sha256
      t.datetime :last_checked_at
      t.datetime :last_imported_at
      t.date     :valid_from
      t.date     :valid_until
      t.integer  :status, null: false, default: 0
      t.text     :last_error
      t.integer  :active_version, null: false, default: 0
      t.jsonb    :import_stats,   null: false, default: {}
      t.timestamps
    end
    add_index :gtfs_feeds, :key, unique: true

    create_table :gtfs_stops do |t|
      t.references :feed, null: false, index: false, foreign_key: { to_table: :gtfs_feeds, on_delete: :cascade }
      t.integer :version, null: false
      t.string  :gtfs_id, null: false
      t.string  :name,    null: false, default: ''
      t.integer :location_type, null: false, default: 0
      t.string  :parent_station_gtfs_id
      t.string  :platform_code
      t.st_point :lonlat, geographic: true, null: false
    end
    add_index :gtfs_stops, %i[feed_id version gtfs_id], unique: true
    add_index :gtfs_stops, :lonlat, using: :gist

    create_table :gtfs_routes do |t|
      t.references :feed, null: false, index: false, foreign_key: { to_table: :gtfs_feeds, on_delete: :cascade }
      t.integer :version, null: false
      t.string  :gtfs_id, null: false
      t.string  :agency_gtfs_id
      t.string  :short_name
      t.string  :long_name
      t.integer :route_type, null: false
      t.string  :color
      t.string  :text_color
    end
    add_index :gtfs_routes, %i[feed_id version gtfs_id], unique: true

    create_table :gtfs_trips do |t|
      t.references :feed, null: false, index: false, foreign_key: { to_table: :gtfs_feeds, on_delete: :cascade }
      t.integer :version,         null: false
      t.string  :gtfs_id,         null: false
      t.string  :route_gtfs_id,   null: false
      t.string  :service_gtfs_id, null: false
      t.string  :headsign
      t.string  :short_name
      t.integer :direction_id
      t.string  :shape_gtfs_id
      t.integer :first_departure_secs
      t.integer :last_arrival_secs
      # false when stop_times are not monotonic: the matcher must skip the trip.
      t.boolean :times_valid, null: false, default: true
    end
    add_index :gtfs_trips, %i[feed_id version gtfs_id], unique: true
    add_index :gtfs_trips, %i[feed_id version service_gtfs_id]
    add_index :gtfs_trips, %i[feed_id version route_gtfs_id]

    create_table :gtfs_stop_times do |t|
      t.references :feed, null: false, index: false, foreign_key: { to_table: :gtfs_feeds, on_delete: :cascade }
      t.integer :version,       null: false
      t.string  :trip_gtfs_id,  null: false
      t.string  :stop_gtfs_id,  null: false
      t.integer :stop_sequence, null: false
      t.integer :arrival_secs
      t.integer :departure_secs
      t.boolean :interpolated, null: false, default: false
    end
    add_index :gtfs_stop_times, %i[feed_id version trip_gtfs_id stop_sequence],
              unique: true, name: 'idx_gtfs_stop_times_trip_seq'
    add_index :gtfs_stop_times, %i[feed_id version stop_gtfs_id departure_secs],
              name: 'idx_gtfs_stop_times_stop_time'

    # Pre-expanded calendar: which service_id runs on which service date.
    create_table :gtfs_service_days do |t|
      t.references :feed, null: false, index: false, foreign_key: { to_table: :gtfs_feeds, on_delete: :cascade }
      t.integer :version,         null: false
      t.string  :service_gtfs_id, null: false
      t.date    :service_date,    null: false
    end
    add_index :gtfs_service_days, %i[feed_id version service_date service_gtfs_id],
              unique: true, name: 'idx_gtfs_service_days_lookup'

    create_table :gtfs_shapes do |t|
      t.references :feed, null: false, index: false, foreign_key: { to_table: :gtfs_feeds, on_delete: :cascade }
      t.integer :version, null: false
      t.string  :gtfs_id, null: false
      t.line_string :path, geographic: true, null: false
      t.float :length_m
    end
    add_index :gtfs_shapes, %i[feed_id version gtfs_id], unique: true
    add_index :gtfs_shapes, :path, using: :gist

    create_table :gtfs_frequencies do |t|
      t.references :feed, null: false, index: false, foreign_key: { to_table: :gtfs_feeds, on_delete: :cascade }
      t.integer :version,      null: false
      t.string  :trip_gtfs_id, null: false
      t.integer :start_secs,   null: false
      t.integer :end_secs,     null: false
      t.integer :headway_secs, null: false
      t.integer :exact_times,  null: false, default: 0
    end
    add_index :gtfs_frequencies, %i[feed_id version trip_gtfs_id]
  end
end
# rubocop:enable Rails/CreateTableWithTimestamps
