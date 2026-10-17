# frozen_string_literal: true

# Review M1/M2 (spec 15, gate D). Only the derived tables change; `points`
# is neither read for writing nor locked.
#
# M2: the boarding and alighting stop positions are stored with each segment,
#     so privacy zones added later can be applied to old rides even after
#     their timetable version is gone (decision K4). Existing rows are filled
#     from the stop (while its version still exists), else from the first /
#     last linked point.
# M1: a segment whose points have all been deleted is deleted too. The
#     ON DELETE CASCADE from points removes the links; this deferred trigger
#     then removes segments left without any link at the end of the
#     transaction (deferred, so replacing the links of a segment inside one
#     transaction does not count as "no links").
#
# The trigger was dropped again by 20261010170100 (review H5).
#
# schema.rb cannot hold triggers: Gtfs::SegmentCleanup::ORPHAN_TRIGGER_SQL
# has the same definition, the specs install it when the test database was
# loaded from schema.rb, and the daily match job also removes orphaned
# segments, so a missing trigger only delays the cleanup.
class AddPrivacyCleanupToTransitSegments < ActiveRecord::Migration[8.1]
  # Review H4: never queue for a lock or run long (see docs/gtfs-deploy.md).
  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '5min'")
    super
  end

  def up
    add_column :transit_segments, :boarding_lonlat, :st_point, geographic: true
    add_column :transit_segments, :alighting_lonlat, :st_point, geographic: true

    execute <<~SQL.squish
      UPDATE transit_segments s
         SET boarding_lonlat = b.lonlat
        FROM gtfs_stops b
       WHERE b.feed_id = s.feed_id AND b.version = s.feed_version AND b.gtfs_id = s.boarding_stop_gtfs_id
    SQL
    execute <<~SQL.squish
      UPDATE transit_segments s
         SET alighting_lonlat = a.lonlat
        FROM gtfs_stops a
       WHERE a.feed_id = s.feed_id AND a.version = s.feed_version AND a.gtfs_id = s.alighting_stop_gtfs_id
    SQL
    execute <<~SQL.squish
      UPDATE transit_segments s
         SET boarding_lonlat = COALESCE(s.boarding_lonlat, (
               SELECT p.lonlat FROM transit_segment_points l JOIN points p ON p.id = l.point_id
                WHERE l.transit_segment_id = s.id ORDER BY p.timestamp ASC LIMIT 1)),
             alighting_lonlat = COALESCE(s.alighting_lonlat, (
               SELECT p.lonlat FROM transit_segment_points l JOIN points p ON p.id = l.point_id
                WHERE l.transit_segment_id = s.id ORDER BY p.timestamp DESC LIMIT 1))
       WHERE s.boarding_lonlat IS NULL OR s.alighting_lonlat IS NULL
    SQL

    execute <<~SQL
      CREATE OR REPLACE FUNCTION gtfs_delete_orphaned_transit_segment() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        DELETE FROM transit_segments s
         WHERE s.id = OLD.transit_segment_id
           AND NOT EXISTS (SELECT 1 FROM transit_segment_points p WHERE p.transit_segment_id = OLD.transit_segment_id);
        RETURN NULL;
      END
      $$;
    SQL
    execute <<~SQL
      CREATE CONSTRAINT TRIGGER transit_segment_points_orphan_cleanup
        AFTER DELETE ON transit_segment_points
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION gtfs_delete_orphaned_transit_segment();
    SQL

    # segments whose points were deleted before this migration
    execute <<~SQL.squish
      DELETE FROM transit_segments s
       WHERE NOT EXISTS (SELECT 1 FROM transit_segment_points p WHERE p.transit_segment_id = s.id)
    SQL
  end

  def down
    execute 'DROP TRIGGER IF EXISTS transit_segment_points_orphan_cleanup ON transit_segment_points'
    execute 'DROP FUNCTION IF EXISTS gtfs_delete_orphaned_transit_segment()'
    remove_column :transit_segments, :alighting_lonlat
    remove_column :transit_segments, :boarding_lonlat
  end
end
