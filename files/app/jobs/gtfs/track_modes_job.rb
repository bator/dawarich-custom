# frozen_string_literal: true

# Every 20 minutes (config/schedule.yml, GTFS_TRACK_MODES_CRON), and for one
# user right after a ride is reviewed (Gtfs::SegmentReview):
# 1. the transport modes users set by hand are stored and written back onto
#    rebuilt tracks (TrackModeCorrections), for every user who has some;
# 2. the segments under confirmed rides get the ride's mode (Gtfs::TrackModes)
#    for the last DAYS days, for every opted-in user, so rebuilt tracks get it
#    back soon. This part is a no-op unless GTFS_ENABLED.
class Gtfs::TrackModesJob < ApplicationJob
  queue_as :gtfs

  DAYS = 7

  def perform(user_id = nil)
    keep_corrections(user_id)
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

  private

  def keep_corrections(user_id)
    hand_set = TrackSegment.joins(:track).where.not(corrected_at: nil)
                           .where(source: TrackModeCorrections::SOURCE).select('tracks.user_id')
    users = User.where(id: TrackModeCorrection.select(:user_id)).or(User.where(id: hand_set))
    users = users.where(id: user_id) if user_id
    users.find_each do |user|
      keeper = TrackModeCorrections.new(user)
      captured, dropped = keeper.capture!
      written = keeper.restore!
      next if [captured, dropped, written].all?(&:zero?)

      Rails.logger.info("[track mode corrections] user #{user.id}: captured #{captured}, dropped #{dropped}, " \
                        "written back #{written}")
    rescue StandardError => e
      Rails.logger.warn("[track mode corrections] user #{user.id}: #{e.class}: #{e.message}")
    end
  end
end
