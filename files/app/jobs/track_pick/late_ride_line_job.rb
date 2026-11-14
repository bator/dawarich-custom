# frozen_string_literal: true

# Writes the timetable line of rides matched or confirmed after the day's track pick
# (TrackPick::LateRideLine). Enqueued after a day is matched (Gtfs::MatchUserDaysJob) and after
# a ride is confirmed (Gtfs::SegmentReview); only the target user's rides are touched.
class TrackPick::LateRideLineJob < ApplicationJob
  queue_as :gtfs

  def perform(user_id, date)
    return unless user_id.to_i == TrackPick::Config.target_user.id

    TrackPick::LateRideLine.new(Date.parse(date.to_s)).call
  rescue ActiveRecord::RecordNotFound
    nil
  end
end
