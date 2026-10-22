# frozen_string_literal: true

# Recomputes transit_walk_legs.covered with the rule of TransitWalkLeg.covered_sql
# as of this migration (docs/atlas.md "Only the snapped line"): only pairs of
# points the snap matched are covered. 20261022120000 covered every pair under
# any drawn part, also the standing-still clouds and recorded parts the layer
# draws as dots or a faint dotted line, so the map lost the raw track line there
# and the way looked broken (2026-10-22). Derived data; down restores nothing
# (the rows are refilled by the same rule as up).
class RecomputeCoveredOfTransitWalkLegs < ActiveRecord::Migration[8.1]
  # TransitWalkLeg.covered_sql as of this migration, with the default limits
  # (RAW_MAX_SEGMENT_M 60, MAX_P95_M 50, along 25 m, coordinates within 2e-6 degrees)
  COVERED_SQL = <<~'SQL'.squish
    (SELECT range_agg(int8range(s.previous_timestamp::bigint, s.timestamp::bigint, '[)')) FROM (SELECT
    (SELECT ST_Multi(ST_Collect(drawn_part.line ORDER BY drawn_part.idx))::geography FROM (SELECT part.idx,
    CASE WHEN cardinality(v.pts) > 1 THEN ST_MakeLine(v.pts) ELSE ST_MakeLine(v.pts[1], v.pts[1]) END AS
    line FROM (SELECT * FROM jsonb_array_elements(transit_walk_legs.parts) WITH ORDINALITY AS part(value,
    idx) WHERE part.value->>'source' IN ('valhalla') ) AS part CROSS JOIN LATERAL (SELECT
    array_agg(ST_SetSRID(ST_MakePoint((c.value->>0)::float8, (c.value->>1)::float8), 4326) ORDER BY c.n) AS
    pts FROM jsonb_array_elements(CASE WHEN jsonb_typeof(part.value->'coords') = 'array' THEN
    part.value->'coords' ELSE '[]'::jsonb END) WITH ORDINALITY AS c(value, n) WHERE c.value->>0 IS NOT NULL
    AND c.value->>1 IS NOT NULL) AS v WHERE v.pts IS NOT NULL) AS drawn_part) AS g) AS snapped, (SELECT
    q.timestamp, q.position, q.recorded, LAG(q.position) OVER w AS previous_position, LAG(q.timestamp) OVER
    w AS previous_timestamp, LAG(q.recorded) OVER w AS previous_recorded FROM (SELECT p.id, p.timestamp,
    p.lonlat::geometry AS position, EXISTS (SELECT 1 FROM jsonb_array_elements(transit_walk_legs.parts) AS
    part, jsonb_array_elements(CASE WHEN jsonb_typeof(part.value->'coords') = 'array' THEN
    part.value->'coords' ELSE '[]'::jsonb END) AS c WHERE part.value->>'source' IN ('raw', 'stationary') AND
    abs((c.value->>0)::float8 - ST_X(p.lonlat::geometry)) < 2.0e-06 AND abs((c.value->>1)::float8 -
    ST_Y(p.lonlat::geometry)) < 2.0e-06) AS recorded FROM points p WHERE p.id =
    ANY(transit_walk_legs.point_ids) AND p.lonlat IS NOT NULL) AS q WINDOW w AS (ORDER BY q.timestamp,
    q.id)) AS s WHERE snapped.g IS NOT NULL AND s.previous_position IS NOT NULL AND s.timestamp >
    s.previous_timestamp AND NOT s.recorded AND NOT s.previous_recorded AND
    ((ST_Length((ST_MakeLine(s.previous_position, s.position))::geography) <= 60.0 AND ST_DWithin(snapped.g,
    (s.previous_position)::geography, 50.0) AND ST_DWithin(snapped.g, (s.position)::geography, 50.0)) OR
    (ST_DWithin(snapped.g, (s.previous_position)::geography, 25.0) AND ST_DWithin(snapped.g,
    (s.position)::geography, 25.0) AND ST_DWithin(snapped.g,
    (ST_LineInterpolatePoint(ST_MakeLine(s.previous_position, s.position), 0.25))::geography, 25.0) AND
    ST_DWithin(snapped.g, (ST_LineInterpolatePoint(ST_MakeLine(s.previous_position, s.position),
    0.5))::geography, 25.0) AND ST_DWithin(snapped.g,
    (ST_LineInterpolatePoint(ST_MakeLine(s.previous_position, s.position), 0.75))::geography, 25.0))))
  SQL

  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '15min'")
    super
  end

  def up
    execute("UPDATE transit_walk_legs SET covered = CASE WHEN drawn IS NULL THEN NULL ELSE #{COVERED_SQL} END")
  end

  def down
    # the earlier rule is not restored: the legs keep the covered times of this one
  end
end
