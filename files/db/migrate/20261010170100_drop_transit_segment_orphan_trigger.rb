# frozen_string_literal: true

# Review H5: the deferred row-level orphan-cleanup trigger of 20261010140100
# ran once per deleted point link inside the user's point deletion (memory
# and time for bulk deletes, possible deadlocks with the matcher, a failure
# aborted the user's deletion) and could not be kept in schema.rb.
#
# Without it nothing changes for the user: TransitSegment.reviewable_for /
# visible_for already require at least one linked point, so a ride whose
# points were all deleted disappears from the web, API and map at once
# (ON DELETE CASCADE removes the links), and Gtfs::MatchRecentJob deletes such
# rows daily (Gtfs::SegmentCleanup.delete_orphans!, one set-based DELETE).
# No trigger on any table any more; `points` is not touched.
class DropTransitSegmentOrphanTrigger < ActiveRecord::Migration[8.1]
  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '5min'")
    super
  end

  def up
    execute 'DROP TRIGGER IF EXISTS transit_segment_points_orphan_cleanup ON transit_segment_points'
    execute 'DROP FUNCTION IF EXISTS gtfs_delete_orphaned_transit_segment()'
  end

  def down
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
  end
end
