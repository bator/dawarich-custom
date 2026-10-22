# frozen_string_literal: true

# A walking leg next to transit rides, snapped to footpaths with Valhalla
# (Gtfs::Walk::DaySnap, docs/gtfs-walk.md). Derived data only: it never
# changes points; point_ids / ride_ids are plain arrays checked by
# Gtfs::Walk::Cleanup. `parts` is the geometry, in time order:
# [{ 'source' => 'valhalla'|'raw'|'stationary', 'coords' => [[lon, lat], ...] },
#  { 'source' => 'gap', 'secs' => .., 'm' => .. } (a jump that is not drawn)]
class TransitWalkLeg < ApplicationRecord
  belongs_to :user

  # `covered` (int8multirange, see COVERED_SQL) has no Active Record type;
  # it is only written and read in SQL
  self.ignored_columns += %w[covered]

  SOURCES = %w[valhalla mixed raw].freeze
  validates :source, inclusion: { in: SOURCES }

  # SQL: the coordinates of `part` (a jsonb_array_elements row), [] when
  # it has none (gap parts)
  PART_COORDS_SQL = "jsonb_array_elements(CASE WHEN jsonb_typeof(part.value->'coords') = 'array' " \
                    "THEN part.value->'coords' ELSE '[]'::jsonb END)"

  # Everything that may be shown to the user (review A-5; read by
  # Gtfs::WalkLegQuery for the API and the map): only the user's
  # own legs while matching is enabled and the account is not excluded, only
  # legs whose points all still exist and that still belong to a ride, never
  # a leg touching one of the user's privacy zones. Fail closed (review K1):
  # without GTFS_WALK_SNAP_EXCLUDE_EMAILS in this process nothing is shown,
  # so a web process with a different env never shows an excluded account.
  def self.visible_for(user, zones: Users::PrivacyZones.new(user).call)
    return none unless Gtfs::Walk::Config.exclude_list_set?
    return none if !Gtfs::UserSettings.new(user).enabled? || Gtfs::Walk::Config.excluded?(user)

    scope = where(user_id: user.id).where.not(missing_points_condition).where.not(orphan_condition)
    zones.empty? ? scope : scope.where.not(zone_condition(zones))
  end

  after_save :refresh_drawn!, if: :saved_change_to_parts?
  after_save :refresh_covered!, if: :saved_change_to_parts? # reads the drawn line just refreshed

  # SQL: the drawn geometry of a leg from its parts column, as stored in
  # `drawn` (review K-new-1): every part with coordinates as one line of a
  # geography MultiLineString (a single coordinate as a zero-length line);
  # gap parts and null coordinates are left out, NULL when nothing is
  # drawn. Same rule as the jsonb fallback in zone_condition
  # and as Gtfs::Walk::ZoneCheck.
  def self.drawn_sql(parts = 'transit_walk_legs.parts')
    '(SELECT ST_Multi(ST_Collect(drawn_part.line ORDER BY drawn_part.idx))::geography FROM (' \
      'SELECT part.idx, CASE WHEN cardinality(v.pts) > 1 THEN ST_MakeLine(v.pts) ' \
      'ELSE ST_MakeLine(v.pts[1], v.pts[1]) END AS line ' \
      "FROM jsonb_array_elements(#{parts}) WITH ORDINALITY AS part(value, idx) " \
      'CROSS JOIN LATERAL (SELECT array_agg(ST_SetSRID(ST_MakePoint((c.value->>0)::float8, ' \
      '(c.value->>1)::float8), 4326) ORDER BY c.n) AS pts ' \
      "FROM #{PART_COORDS_SQL} WITH ORDINALITY AS c(value, n) " \
      'WHERE c.value->>0 IS NOT NULL AND c.value->>1 IS NOT NULL) AS v ' \
      'WHERE v.pts IS NOT NULL) AS drawn_part)'
  end

  # The assignment refresh_drawn! runs: drawn_sql of this table, built once
  # from constants (no input reaches the SQL; review A-8-4)
  DRAWN_ASSIGNMENT = "drawn = #{drawn_sql}".freeze

  # SQL: a leg with a drawable coordinate but no stored `drawn`, e.g.
  # written by older code after a rollback (review A-8-2; such a leg is
  # correct through the fallback, only slower). Cheap (no geometry is
  # built), for health checks.
  # (strict jsonpath: lax mode would unwrap the coordinate pair before the
  # filter)
  MISSING_DRAWN_SQL = 'transit_walk_legs.drawn IS NULL AND transit_walk_legs.parts @? ' \
                      '\'strict $[*] ? (@.coords.type() == "array").coords[*] ? ' \
                      '(@.type() == "array" && @[0] != null && @[1] != null)\''
  scope :missing_drawn, -> { where(MISSING_DRAWN_SQL) }

  # SQL: the stored `drawn` is not what `parts` draws today: missing (as
  # above), outdated (parts changed without refresh_drawn!, e.g. by an
  # update_all / update_columns that skips the callback, review A-9-3), or
  # left over after parts lost every drawable coordinate. Rebuilds every
  # leg's lines from parts (~1 ms per leg): for gtfs:walk_refresh_drawn,
  # not for requests. Today parts are only written by LegWriter (insert_all
  # + refresh_drawn!) and by save (after_save), see the guard in
  # spec/services/gtfs/walk/zone_check_spec.rb.
  STALE_DRAWN_SQL = "ST_AsBinary(transit_walk_legs.drawn) IS DISTINCT FROM ST_AsBinary(#{drawn_sql})".freeze
  scope :stale_drawn, -> { where(STALE_DRAWN_SQL) }

  # Fills `drawn` for the given legs (LegWriter after insert_all, and after
  # every save that changes parts).
  def self.refresh_drawn!(ids)
    where(id: ids).update_all(DRAWN_ASSIGNMENT)
  end

  # The map's Tracks tiles leave out the raw GPS line where this leg's drawn
  # line runs under it (Gtfs::TrackCutouts, docs/atlas.md "Only the snapped
  # line"). `covered` holds those times: every pair of the leg's consecutive
  # points [t1, t2) whose segment lies under `drawn`, merged. A pair is under
  # it when it is no longer than the layer's own gap limit
  # (RAW_MAX_SEGMENT_M) and its ends and middle lie within NEAR_M of the
  # drawn line (the snap's p95 limit), or when the drawn line runs along all
  # of it (ends, quarters, middle within ALONG_M; a snapped run across a GPS
  # gap). A GPS gap the layer does not draw stays out, so the raw line joins
  # the walk there. Measured on a week of user 2's walks (3781 segments):
  # every gap kept, every segment under the drawn line covered.
  COVERED_NEAR_M = Gtfs::Walk::Config::MAX_P95_M
  COVERED_ALONG_M = 25

  def self.covered_sql
    line = 'ST_MakeLine(s.previous_position, s.position)'
    near = ->(point, metres) { "ST_DWithin(transit_walk_legs.drawn, (#{point})::geography, #{metres.to_f})" }
    at = ->(fraction) { "ST_LineInterpolatePoint(#{line}, #{fraction})" }
    <<~SQL.squish
      (SELECT range_agg(int8range(s.previous_timestamp::bigint, s.timestamp::bigint, '[)'))
       FROM (SELECT p.timestamp, p.lonlat::geometry AS position,
               LAG(p.lonlat::geometry) OVER w AS previous_position, LAG(p.timestamp) OVER w AS previous_timestamp
             FROM points p WHERE p.id = ANY(transit_walk_legs.point_ids) AND p.lonlat IS NOT NULL
             WINDOW w AS (ORDER BY p.timestamp, p.id)) AS s
       WHERE s.previous_position IS NOT NULL AND s.timestamp > s.previous_timestamp
         AND ((ST_Length((#{line})::geography) <= #{Gtfs::Walk::Config::RAW_MAX_SEGMENT_M.to_f}
               AND #{near.('s.previous_position', COVERED_NEAR_M)} AND #{near.('s.position', COVERED_NEAR_M)}
               AND #{near.(at.(0.5), COVERED_NEAR_M)})
           OR (#{near.('s.previous_position', COVERED_ALONG_M)} AND #{near.('s.position', COVERED_ALONG_M)}
               AND #{[0.25, 0.5, 0.75].map { |f| near.(at.(f), COVERED_ALONG_M) }.join(' AND ')})))
    SQL
  end

  # Fills `covered` for the given legs (after refresh_drawn!, which it reads)
  def self.refresh_covered!(ids)
    where(id: ids).update_all("covered = CASE WHEN drawn IS NULL THEN NULL ELSE #{covered_sql} END")
  end

  def refresh_covered!
    self.class.refresh_covered!(id)
  end

  def refresh_drawn!
    self.class.refresh_drawn!(id)
  end

  # SQL: a drawn part of the leg comes within a zone's radius
  # ([{ lon:, lat:, radius: }]). Each part with coordinates is tested as the
  # line that is drawn (a single coordinate as a point), on the geography, so
  # a snapped segment crossing a zone between two vertices counts too
  # (review K2; Ruby twin: Gtfs::Walk::ZoneCheck).
  #
  # Cost (review K-new-1): legs with the stored `drawn` geography are found
  # by one uncorrelated subquery that the GiST index answers (legs near a
  # zone), so the per-row test is a hash lookup, also under NOT for
  # visible_for (ST_DWithin per row on the geography took ~1.8 s for 2000
  # legs and 5 zones; the subquery ~20 ms). A leg without `drawn` (written
  # before the column, or by code that did not fill it) falls back to
  # building the lines from `parts`, so it is never shown unchecked.
  def self.zone_condition(zones)
    '(transit_walk_legs.id IN (SELECT near_zone.id FROM transit_walk_legs AS near_zone ' \
      "WHERE near_zone.drawn IS NOT NULL AND (#{zone_checks(zones, 'near_zone.drawn').join(' OR ')})) OR " \
      '(transit_walk_legs.drawn IS NULL AND EXISTS (SELECT 1 ' \
      'FROM jsonb_array_elements(transit_walk_legs.parts) AS part(value) ' \
      'CROSS JOIN LATERAL (SELECT array_agg(ST_SetSRID(ST_MakePoint((coord.value->>0)::float8, ' \
      "(coord.value->>1)::float8), 4326) ORDER BY coord.n) AS pts FROM #{PART_COORDS_SQL} " \
      'WITH ORDINALITY AS coord(value, n)) AS vertices ' \
      'CROSS JOIN LATERAL (SELECT (CASE WHEN cardinality(vertices.pts) > 1 THEN ST_MakeLine(vertices.pts) ' \
      'ELSE vertices.pts[1] END)::geography AS geog) AS drawn ' \
      "WHERE drawn.geog IS NOT NULL AND (#{zone_checks(zones, 'drawn.geog').join(' OR ')}))))"
  end

  def self.zone_checks(zones, column)
    zones.map do |zone|
      sanitize_sql_array(["ST_DWithin(#{column}, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?)",
                          zone[:lon].to_f, zone[:lat].to_f, zone[:radius].to_f])
    end
  end
  private_class_method :zone_checks

  # SQL: one of the leg's recorded points was deleted (review M4).
  def self.missing_points_condition
    'EXISTS (SELECT 1 FROM unnest(transit_walk_legs.point_ids) AS leg_point(id) ' \
      'WHERE NOT EXISTS (SELECT 1 FROM points WHERE points.id = leg_point.id))'
  end

  # SQL: none of the leg's rides is still there and not rejected (review M5).
  # Legs without rides (scope `all`, evaluation) are not orphans.
  def self.orphan_condition
    sanitize_sql_array(['cardinality(transit_walk_legs.ride_ids) > 0 AND NOT EXISTS ' \
                        '(SELECT 1 FROM transit_segments WHERE transit_segments.id = ANY(transit_walk_legs.ride_ids) ' \
                        'AND transit_segments.status <> ?)', TransitSegment.statuses[:rejected]])
  end
end
