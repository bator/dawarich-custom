# frozen_string_literal: true

# Sets the transport mode of the track segments under confirmed rides
# (Gtfs::TrackModes) for the last DAYS days: every 20 minutes for every
# opted-in user (config/schedule.yml, GTFS_TRACK_MODES_CRON), so rebuilt
# tracks get it back soon, and for one user right after a ride is reviewed
# (Gtfs::SegmentReview). No-op unless GTFS_ENABLED.
class Gtfs::TrackModesJob < ApplicationJob
  queue_as :gtfs

  DAYS = 7

  def perform(user_id = nil)
    return unless Gtfs.enabled?

    users = Gtfs::UserSettings.opted_in_users
    users = users.where(id: user_id) if user_id
    users.find_each do |user|
      today = Gtfs::MatchDay.today_for(user)
      from, = Gtfs::MatchDay.day_range(user, today - DAYS)
      _, to = Gtfs::MatchDay.day_range(user, today)
      changes = Gtfs::TrackModes.new(user, from:, to:).call
      Rails.logger.info("[GTFS track modes] user #{user.id}: #{changes.size} segment(s) changed") if changes.any?
    rescue StandardError => e
      Rails.logger.warn("[GTFS track modes] user #{user.id}: #{e.class}: #{e.message}")
    end
  end
end
