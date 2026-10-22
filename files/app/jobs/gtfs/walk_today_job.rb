# frozen_string_literal: true

# Hourly during the day (config/schedule.yml, GTFS_WALK_TODAY_CRON, default
# minute 17 from 06 to 23 Europe/Budapest): snaps today's walking legs so far
# for every opted-in user, so a walk shows snapped on the map the same day
# instead of after the night's match (docs/atlas.md, "Walks the same day").
#
# Walks only: rides are matched at night (Gtfs::MatchRecentJob), so Discord
# gets no ride message during the day and no ride is matched while it is
# still going on. The night's run replaces today's legs with the whole day.
# Under the user's match lock (Gtfs::MatchDay.lock_name); a user whose
# matching is running is skipped, the next hour tries again. No-op unless
# GTFS_ENABLED and GTFS_WALK_SNAP_ENABLED; DaySnap itself skips excluded
# accounts.
class Gtfs::WalkTodayJob < ApplicationJob
  queue_as :gtfs

  def perform
    return unless Gtfs.enabled? && Gtfs::Walk::Config.enabled?

    Gtfs::UserSettings.opted_in_users.find_each do |user|
      snap(user)
    rescue StandardError => e
      Rails.logger.warn("[GTFS walk today] user #{user.id}: #{e.class}: #{e.message}")
    end
  end

  private

  def snap(user)
    from_ts, to_ts = Gtfs::MatchDay.day_range(user, Gtfs::MatchDay.today_for(user))
    lock = ActiveRecord::Base.with_advisory_lock_result(Gtfs::MatchDay.lock_name(user), timeout_seconds: 0) do
      Gtfs::Walk::DaySnap.new(user, from_ts, to_ts, rides: Gtfs::Walk::Rides.saved(user, from_ts, to_ts),
                                                    privacy_zones: Users::PrivacyZones.new(user).call).call
    end
    Rails.logger.info("[GTFS walk today] user #{user.id}: matching is running, next hour") unless lock.lock_was_acquired?
  end
end
