# frozen_string_literal: true

# Drops transit_walk_legs.covered (20261022120000, 20261022130000): the map's
# Tracks tiles now leave out the raw GPS line under all of a walk the walking
# legs layer draws, its time from the first to the last fix
# (Gtfs::TrackCutouts, docs/atlas.md "Only the snapped line"). The layer
# draws the stretches between the snapped parts itself, dashed along the
# recorded fixes, so the times only the snap matched are not needed any more
# (Bator, 2026-10-22). Derived data: down adds the column back empty, where
# older code cuts no walk until its legs are written again.
class RemoveCoveredFromTransitWalkLegs < ActiveRecord::Migration[8.1]
  def up
    remove_column :transit_walk_legs, :covered
  end

  def down
    execute('ALTER TABLE transit_walk_legs ADD COLUMN covered int8multirange')
  end
end
