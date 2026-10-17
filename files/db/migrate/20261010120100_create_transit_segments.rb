# frozen_string_literal: true

# Derived matching results (filled by the Phase 2 matcher). These tables only
# *reference* points; they never modify or delete them. Deleting a point (or a
# user) removes the derived rows via ON DELETE CASCADE, not the other way round.
#
# The foreign key from transit_segment_points to points is added by
# 20261010140000_add_points_foreign_key_to_transit_segment_points, which
# limits how long it may wait for its lock on points (review K5).
class CreateTransitSegments < ActiveRecord::Migration[8.1]
  # Review H4: never queue for a lock or run long (see docs/gtfs-deploy.md).
  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '5min'")
    super
  end

  def change
    create_table :transit_segments do |t|
      t.references :user, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :feed, null: false, foreign_key: { to_table: :gtfs_feeds }
      t.string  :route_gtfs_id
      t.string  :trip_gtfs_id
      t.string  :route_short_name
      t.string  :route_long_name
      t.integer :route_type
      t.string  :headsign
      t.string  :boarding_stop_gtfs_id
      t.string  :boarding_stop_name
      t.string  :alighting_stop_gtfs_id
      t.string  :alighting_stop_name
      t.bigint  :started_at,   null: false
      t.bigint  :ended_at,     null: false
      t.float   :distance_m
      t.float   :confidence,   null: false
      t.integer :status,       null: false, default: 0
      t.integer :point_count,  null: false, default: 0
      t.integer :feed_version, null: false
      t.jsonb   :debug
      t.timestamps
    end
    add_index :transit_segments, %i[user_id started_at]
    add_index :transit_segments, %i[user_id status]

    create_table :transit_segment_points do |t|
      t.references :transit_segment, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :point, null: false # foreign key: see 20261010140000
      t.timestamps
    end
    add_index :transit_segment_points, %i[transit_segment_id point_id], unique: true
  end
end
