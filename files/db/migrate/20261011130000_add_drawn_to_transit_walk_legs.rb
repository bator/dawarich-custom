# frozen_string_literal: true

# The drawn geometry of a walking leg, stored next to `parts` so the privacy
# zone check (TransitWalkLeg.zone_condition) does not rebuild every leg's
# lines from jsonb on each API or map read (review K-new-1). Derived data,
# filled by Gtfs::Walk::LegWriter (TransitWalkLeg.refresh_drawn!); legs
# without it are still checked from `parts`. Reversible: down drops the
# column and its index, nothing else depends on it.
class AddDrawnToTransitWalkLegs < ActiveRecord::Migration[8.1]
  # TransitWalkLeg.drawn_sql as of this migration (kept here so a later
  # change of the model does not change what this migration does)
  DRAWN_SQL = '(SELECT ST_Multi(ST_Collect(drawn_part.line ORDER BY drawn_part.idx))::geography FROM (' \
              'SELECT part.idx, CASE WHEN cardinality(v.pts) > 1 THEN ST_MakeLine(v.pts) ' \
              'ELSE ST_MakeLine(v.pts[1], v.pts[1]) END AS line ' \
              'FROM jsonb_array_elements(transit_walk_legs.parts) WITH ORDINALITY AS part(value, idx) ' \
              'CROSS JOIN LATERAL (SELECT array_agg(ST_SetSRID(ST_MakePoint((c.value->>0)::float8, ' \
              '(c.value->>1)::float8), 4326) ORDER BY c.n) AS pts ' \
              "FROM jsonb_array_elements(CASE WHEN jsonb_typeof(part.value->'coords') = 'array' " \
              "THEN part.value->'coords' ELSE '[]'::jsonb END) WITH ORDINALITY AS c(value, n) " \
              'WHERE c.value->>0 IS NOT NULL AND c.value->>1 IS NOT NULL) AS v ' \
              'WHERE v.pts IS NOT NULL) AS drawn_part)'

  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '5min'")
    super
  end

  def up
    add_column :transit_walk_legs, :drawn, :multi_line_string, geographic: true, srid: 4326
    execute("UPDATE transit_walk_legs SET drawn = #{DRAWN_SQL}")
    add_index :transit_walk_legs, :drawn, using: :gist
  end

  def down
    remove_column :transit_walk_legs, :drawn
  end
end
