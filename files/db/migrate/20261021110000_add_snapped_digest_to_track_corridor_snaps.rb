# frozen_string_literal: true

# Frequent routes (docs/corridors.md): a digest of the geometry the snapper
# wrote (md5 of ST_AsBinary(original_path)). Whether Dawarich rebuilt a
# snapped track is told by its geometry, not by updated_at, which other jobs
# change too (code review 2026-10-21: a mode reclassification made the
# snapped geometry the "original" one and broke corridors:revert).
class AddSnappedDigestToTrackCorridorSnaps < ActiveRecord::Migration[8.1]
  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '5min'")
    super
  end

  def up
    add_column :track_corridor_snaps, :snapped_digest, :string
    # earlier snaps: the track still has the snapped geometry while updated_at is the one written
    execute(<<~SQL.squish)
      UPDATE track_corridor_snaps s SET snapped_digest = md5(ST_AsBinary(t.original_path))
      FROM tracks t
      WHERE t.id = s.track_id AND date_trunc('second', t.updated_at) = date_trunc('second', s.track_updated_at)
    SQL
  end

  def down
    remove_column :track_corridor_snaps, :snapped_digest
  end
end
