# frozen_string_literal: true

# The times a walking leg's drawn line runs under its raw GPS line
# (TransitWalkLeg.covered_sql, docs/atlas.md "Only the snapped line"): the
# map's Tracks tiles leave the raw line out there and keep it across the GPS
# gaps the walking legs layer does not draw. Derived data, filled by
# Gtfs::Walk::LegWriter from now on and here for the existing legs.
# int8multirange has no Active Record type (TransitWalkLeg ignores the
# column). Reversible: down drops the column, nothing else depends on it.
class AddCoveredToTransitWalkLegs < ActiveRecord::Migration[8.1]
  # TransitWalkLeg.covered_sql as of this migration, with the default limits
  # (RAW_MAX_SEGMENT_M 60, MAX_P95_M 50, along 25 m)
  COVERED_SQL = '(SELECT range_agg(int8range(s.previous_timestamp::bigint, s.timestamp::bigint, \'[)\')) FROM ' \
                '(SELECT p.timestamp, p.lonlat::geometry AS position, LAG(p.lonlat::geometry) OVER w AS ' \
                'previous_position, LAG(p.timestamp) OVER w AS previous_timestamp FROM points p WHERE p.id = ' \
                'ANY(transit_walk_legs.point_ids) AND p.lonlat IS NOT NULL WINDOW w AS (ORDER BY p.timestamp, ' \
                'p.id)) AS s WHERE s.previous_position IS NOT NULL AND s.timestamp > s.previous_timestamp AND ' \
                '((ST_Length((ST_MakeLine(s.previous_position, s.position))::geography) <= 60.0 AND ' \
                'ST_DWithin(transit_walk_legs.drawn, (s.previous_position)::geography, 50.0) AND ' \
                'ST_DWithin(transit_walk_legs.drawn, (s.position)::geography, 50.0) AND ' \
                'ST_DWithin(transit_walk_legs.drawn, (ST_LineInterpolatePoint(ST_MakeLine(s.previous_position, ' \
                's.position), 0.5))::geography, 50.0)) OR (ST_DWithin(transit_walk_legs.drawn, ' \
                '(s.previous_position)::geography, 25.0) AND ST_DWithin(transit_walk_legs.drawn, ' \
                '(s.position)::geography, 25.0) AND ST_DWithin(transit_walk_legs.drawn, ' \
                '(ST_LineInterpolatePoint(ST_MakeLine(s.previous_position, s.position), 0.25))::geography, 25.0) ' \
                'AND ST_DWithin(transit_walk_legs.drawn, ' \
                '(ST_LineInterpolatePoint(ST_MakeLine(s.previous_position, s.position), 0.5))::geography, 25.0) ' \
                'AND ST_DWithin(transit_walk_legs.drawn, ' \
                '(ST_LineInterpolatePoint(ST_MakeLine(s.previous_position, s.position), 0.75))::geography, ' \
                '25.0))))'

  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '15min'")
    super
  end

  def up
    execute('ALTER TABLE transit_walk_legs ADD COLUMN covered int8multirange')
    execute("UPDATE transit_walk_legs SET covered = #{COVERED_SQL} WHERE drawn IS NOT NULL")
  end

  def down
    remove_column :transit_walk_legs, :covered
  end
end
