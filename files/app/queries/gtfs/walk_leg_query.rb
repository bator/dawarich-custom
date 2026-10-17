# frozen_string_literal: true

# Reads of the walking legs (transit_walk_legs) for the API and the map,
# with the same parameters as Gtfs::SegmentQuery (start_at / end_at as Unix
# seconds or ISO 8601, page / per_page).
#
# Visibility: TransitWalkLeg.visible_for (opt-in, exclusion, deleted points,
# rejected or deleted rides, privacy zones on every stored coordinate), and
# a leg that belongs to rides is only shown while one of those rides is
# shown itself (TransitSegment.visible_for: display threshold, feed
# selection, zones). Legs without rides (scope `all`) need no ride.
class Gtfs::WalkLegQuery < Gtfs::SegmentQuery
  # The map endpoint, like the rides' (Gtfs::SegmentQuery::MAX_MAP_SEGMENTS),
  # answers at most 500 legs; without start_at it covers the 31 days up to
  # end_at (or now), so a call without a range stays small (review A1).
  MAX_MAP_LEGS = Gtfs::SegmentQuery::MAX_MAP_SEGMENTS
  MAP_DEFAULT_DAYS = 31
  COORD_DIGITS = 6

  def scope
    rides = TransitSegment.visible_for(user, zones: @zones)
                          .where('transit_segments.id = ANY(transit_walk_legs.ride_ids)')
                          .select(1)
    rel = TransitWalkLeg.visible_for(user, zones: @zones)
                        .where("cardinality(transit_walk_legs.ride_ids) = 0 OR EXISTS (#{rides.to_sql})")
    rel = rel.where(started_at: start_at..) if start_at
    rel = rel.where(started_at: ..end_at) if end_at
    rel.order(started_at: :desc, id: :desc)
  end

  # One page plus whether another one follows (one row more is read).
  def page_with_more
    rows = scope.select(*read_columns).offset((page - 1) * per_page).limit(per_page + 1).to_a
    [rows.first(per_page), rows.size > per_page]
  end

  # Counting walks every visible leg through the visibility checks (zones,
  # deleted points), so it is only done for a bounded request (start_at
  # given); without it the API answers total: null and relies on has_more
  # (review K-new-1).
  def total
    start_at ? scope.count : nil
  end

  def map_legs
    rel = scope
    rel = rel.where(started_at: ((end_at || Time.current.to_i) - MAP_DEFAULT_DAYS.days.to_i)..) unless start_at
    rel.select(*read_columns).limit(MAX_MAP_LEGS).to_a
  end

  private

  # Everything but the stored `drawn` geography: the answers are built from
  # `parts`, decoding `drawn` would be wasted (review A-8-6).
  def read_columns
    (TransitWalkLeg.column_names - ['drawn']).map { |c| TransitWalkLeg.arel_table[c] }
  end
end
