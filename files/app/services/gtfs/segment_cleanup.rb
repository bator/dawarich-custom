# frozen_string_literal: true

# Removes derived rides that must not stay around (review M1/M2, spec 15).
# Only transit_segments / transit_segment_points are deleted; points are never
# touched.
#
# - Orphans: segments whose points have all been deleted (the links go with
#   the points, ON DELETE CASCADE). They are hidden at once
#   (TransitSegment.reviewable_for needs a linked point) and deleted here with
#   one set-based DELETE by the daily match job. There is no database trigger
#   any more (review H5: it slowed bulk point deletions down and could not
#   be kept in schema.rb).
# - Privacy zones: `auto` segments that start or end inside one of the
#   user's privacy zones, or whose points lie in one, are deleted (a zone
#   added after the ride was matched). Confirmed and rejected segments are
#   the user's own decision and are kept, but TransitSegment.visible_for
#   hides them while they touch a zone.
module Gtfs::SegmentCleanup
  module_function

  # => number of deleted segments
  def delete_orphans!(scope = TransitSegment.all)
    scope.where.missing(:transit_segment_points).delete_all
  end

  # => number of deleted `auto` segments of the user
  def apply_privacy_zones!(user, zones: Users::PrivacyZones.new(user).call)
    return 0 if zones.empty?

    auto = user.transit_segments.auto
    via_points = TransitSegmentPoint.joins(:point).where(transit_segment_id: auto.select(:id))
                                    .where(TransitSegment.zone_condition(zones, columns: ['points.lonlat']))
                                    .select(:transit_segment_id)
    auto.where(TransitSegment.zone_condition(zones)).or(auto.where(id: via_points)).delete_all
  end
end
