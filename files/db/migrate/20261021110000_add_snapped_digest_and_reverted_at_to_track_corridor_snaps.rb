# frozen_string_literal: true

# Frequent routes (docs/corridors.md), the snap log:
# - snapped_digest: md5 of ST_AsBinary of the geometry the snapper wrote.
#   Whether Dawarich rebuilt a snapped track is told by its geometry, not by
#   updated_at, which other jobs change too (code review 2026-10-21: after a
#   mode reclassification the snapped geometry became the "original" one and
#   corridors:revert lost the recorded one).
# - reverted_at: the snap was put back (corridors:revert); the row stays, so
#   the nightly snap does not snap the track again.
class AddSnappedDigestAndRevertedAtToTrackCorridorSnaps < ActiveRecord::Migration[8.1]
  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '5min'")
    super
  end

  def up
    add_column :track_corridor_snaps, :snapped_digest, :string
    add_column :track_corridor_snaps, :reverted_at, :datetime
    # earlier snaps: a track whose geometry is not the recorded one still has
    # the snapped one (whatever touched updated_at since); keeping the
    # recorded geometry is the safe side, a rebuild can be made again
    execute(<<~SQL.squish)
      UPDATE track_corridor_snaps s SET snapped_digest = md5(ST_AsBinary(t.original_path))
      FROM tracks t
      WHERE t.id = s.track_id AND NOT ST_OrderingEquals(t.original_path, s.original_path)
    SQL
  end

  def down
    remove_column :track_corridor_snaps, :reverted_at
    remove_column :track_corridor_snaps, :snapped_digest
  end
end
