# frozen_string_literal: true

# Removes walking legs that must not stay around (derived data only; points
# are never changed, only read by id):
#
# - privacy zones (review M3): a leg with any stored coordinate (snapped,
#   recorded or stationary) inside one of the user's zones, also a zone added
#   after the leg was saved. MatchDay / DaySnap check the matched day only
#   (review N6); Gtfs::MatchRecentJob checks all legs once a day;
# - deleted points (review M4): a leg one of whose recorded points no longer
#   exists (the leg keeps copies of their coordinates); the nightly job
#   checks the recent legs and a rolling seventh of the older ones (review
#   H-1, delete_stale_nightly!);
# - orphans (review M5): a leg attached to rides none of which is still there
#   and not rejected (a ride rejected on Discord or deleted by
#   Gtfs::SegmentCleanup).
#
# TransitWalkLeg.visible_for applies the same rules when reading, so nothing
# stale is shown between two cleanups.
#
# Callers outside the walk snap (ride matching, the nightly job, rake) use
# `safely`: a failing cleanup or a missing table (migration not run yet) is
# logged and never fails the ride matching (review N2).
module Gtfs::Walk::Cleanup
  module_function

  # => the block's result, or 0 when the table is missing or the block failed
  def safely(what, logger: Rails.logger, &)
    return 0 unless table_ready?

    TransitWalkLeg.transaction(requires_new: true, &)
  rescue StandardError => e
    logger&.warn("[GTFS walk] #{what} failed, skipped: #{e.class}: #{e.message}")
    0
  end

  # Cached once the table exists (a missing table is checked again).
  def table_ready?
    @table_ready ||= TransitWalkLeg.table_exists?
  end

  def reset_table_check! = (@table_ready = nil)

  # => number of deleted legs of the user; window: started_at range (epoch s)
  def apply_privacy_zones!(user, zones: Users::PrivacyZones.new(user).call, window: nil)
    return 0 if zones.empty?

    scope = TransitWalkLeg.where(user_id: user.id)
    scope = scope.where(started_at: window) if window
    scope.where(TransitWalkLeg.zone_condition(zones)).delete_all
  end

  # The legs of a matched day (with the matcher's buffer before it).
  def day_window(from_ts, to_ts) = ((from_ts.to_i - Gtfs::Config::DAY_BUFFER_SECS)..to_ts.to_i)

  # => number of deleted legs of every user that has legs
  def apply_all_privacy_zones!
    User.where(id: TransitWalkLeg.select(:user_id).distinct).find_each.sum { |user| apply_privacy_zones!(user) }
  end

  # => number of deleted legs (scope: e.g. one user's legs). Checks every
  # point id of every leg in the scope (~0.4 ms per leg of 300 points):
  # for one user (gtfs:segment_cleanup) or by hand; the nightly job uses
  # delete_stale_nightly!.
  def delete_stale!(scope = TransitWalkLeg.all)
    scope.where(TransitWalkLeg.missing_points_condition)
         .or(scope.where(TransitWalkLeg.orphan_condition)).delete_all
  end

  # Older legs are checked for deleted points in ROLLING_SLICES nightly
  # slices (by id), so every leg is checked once a week.
  ROLLING_SLICES = 7

  # The nightly cleanup (Gtfs::MatchRecentJob, review H-1): the full
  # deleted-points check grows with all legs ever written, so it only checks
  # - the legs of the recent days (the matched lookback plus a margin; points
  #   are mostly deleted soon after they were recorded or imported),
  # - one rolling slice of the older legs (id % 7 = the day's slice),
  # and orphans (cheap: a few ride ids per leg) of all legs.
  # A leg with a deleted point is never shown in the meantime:
  # TransitWalkLeg.visible_for checks it on every read; the cleanup only
  # removes the row. => number of deleted legs
  def delete_stale_nightly!(now: Time.current)
    nightly_points_scope(now).where(TransitWalkLeg.missing_points_condition)
                             .or(TransitWalkLeg.where(TransitWalkLeg.orphan_condition)).delete_all
  end

  # Legs whose points the nightly cleanup checks (see delete_stale_nightly!)
  def nightly_points_scope(now = Time.current)
    since = (now - (Gtfs::Config::MATCH_LOOKBACK_DAYS + 2).days).to_i
    slice = now.to_date.jd % ROLLING_SLICES
    TransitWalkLeg.where(started_at: since..)
                  .or(TransitWalkLeg.where('transit_walk_legs.id % ? = ?', ROLLING_SLICES, slice))
  end

  # A user who is excluded (or opted out) later keeps no legs (review A-2).
  def delete_for_user!(user)
    TransitWalkLeg.where(user_id: user.id).delete_all
  end
end
