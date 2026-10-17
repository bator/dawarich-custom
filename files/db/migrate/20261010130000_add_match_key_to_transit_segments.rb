# frozen_string_literal: true

# Phase 2 (spec 9.10): matcher results are saved idempotently per
# (user, feed, trip, started_at). transit_segments only holds derived data;
# the points table is not touched.
class AddMatchKeyToTransitSegments < ActiveRecord::Migration[8.1]
  # Review H4: never queue for a lock or run long (see docs/gtfs-deploy.md).
  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '5min'")
    super
  end

  def change
    add_index :transit_segments, %i[user_id feed_id trip_gtfs_id started_at],
              unique: true, name: 'idx_transit_segments_match_key'
  end
end
