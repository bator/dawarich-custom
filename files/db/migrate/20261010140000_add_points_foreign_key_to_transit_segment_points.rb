# frozen_string_literal: true

# The only lock the GTFS tables take on `points`: adding this foreign key
# needs a short SHARE ROW EXCLUSIVE lock on the points table (no row is read
# or changed). On a busy database a long-running transaction on points would
# make the migration wait and queue every new point INSERT behind it, so it
# gives up after a few seconds instead; just run the migration again later
# (spec 10, review K5).
#
# This used to be part of 20261010120100_create_transit_segments. Databases
# that already ran that migration have the key and skip this one; on all
# others the key is created here, with the lock timeout in effect.
class AddPointsForeignKeyToTransitSegmentPoints < ActiveRecord::Migration[8.1]
  # Review H4: never queue for a lock or run long (see docs/gtfs-deploy.md).
  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '5min'")
    super
  end

  def up
    return if foreign_key_exists?(:transit_segment_points, :points)

    execute "SET LOCAL lock_timeout = '5s'"
    add_foreign_key :transit_segment_points, :points, on_delete: :cascade
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    remove_foreign_key :transit_segment_points, :points, if_exists: true
  end
end
