# frozen_string_literal: true

# Daily (config/schedule.yml, GTFS_MATCH_CRON, default 03:00 Europe/Budapest,
# i.e. before the 03:30 feed sync): matches the last GTFS_MATCH_LOOKBACK_DAYS
# days of every opted-in user, counted in the user's own time zone (review
# A12), one job per day (review K4).
#
# Decision K4 keeps only the active and one backup timetable per feed, so a
# day can only be matched while its timetable is one of those two. For feeds
# that are replaced daily (BKK) that is about two days; running before the
# next feed update with a two-day lookback matches every day at least once,
# and catches points that were uploaded late.
#
# It also removes segments whose points were all deleted (review M1; they
# are hidden from the moment their points are gone, see
# TransitSegment.reviewable_for) and brings the Discord messages in line
# (deleted/hidden rides, review H3).
class Gtfs::MatchRecentJob < ApplicationJob
  queue_as :gtfs

  def perform
    return unless Gtfs.enabled?

    orphans = Gtfs::SegmentCleanup.delete_orphans!
    Rails.logger.info("[GTFS match] removed #{orphans} segment(s) without points") if orphans.positive?
    clean_walking_legs
    Gtfs::Discord::MessageCleanupJob.perform_later if Gtfs::Discord::Config.enabled?

    Gtfs::UserSettings.opted_in_users.find_each do |user|
      today = Gtfs::MatchDay.today_for(user)
      Gtfs::MatchUserDaysJob.enqueue_days(user.id, (today - Gtfs::Config::MATCH_LOOKBACK_DAYS)..(today - 1))
    end
  end

  private

  # Never stops the scheduling (review N2), see Gtfs::Walk::Cleanup.safely.
  def clean_walking_legs
    cleanup = Gtfs::Walk::Cleanup
    stale = cleanup.safely('stale leg cleanup') { cleanup.delete_stale_nightly! }
    zones = cleanup.safely('privacy zone cleanup') { cleanup.apply_all_privacy_zones! }
    return unless (stale + zones).positive?

    Rails.logger.info("[GTFS walk] removed #{stale} stale walking leg(s), #{zones} in privacy zones")
  end
end
