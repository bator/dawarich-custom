# frozen_string_literal: true

# First-run backfill (spec 10): matches a user's past days, going backwards
# in time from yesterday, one day per job. It can be cancelled and resumed;
# the state is kept in gtfs_user_states.backfill for the UI (Phase 3):
#
#   status      running | done | cancelled
#   from        first day processed (yesterday at start)
#   until       oldest day that can still be matched (see below)
#   cursor      next day to process
#   days_done   days processed so far
#   started_at / updated_at / finished_at (ISO 8601)
#
# Only days for which some enabled feed still has a timetable version can be
# matched (decision K4: active + one backup), so the backfill stops at the
# earliest service date of those versions, or at the user's first point.
class Gtfs::Backfill
  def self.status(user)
    Gtfs::UserState.find_by(user_id: user.id)&.backfill || {}
  end

  # Starts, or resumes from the saved cursor if a previous run did not finish.
  def self.start!(user, restart: false)
    state = update!(user) do |current|
      if restart || current.empty? || current['status'] == 'done'
        yesterday = Gtfs::MatchDay.today_for(user) - 1
        { 'status' => 'running', 'from' => yesterday.iso8601, 'cursor' => yesterday.iso8601,
          'until' => oldest_date(user)&.iso8601, 'days_done' => 0,
          'started_at' => Time.current.iso8601, 'finished_at' => nil }
      else
        current.merge('status' => 'running', 'until' => oldest_date(user)&.iso8601)
      end
    end
    Gtfs::BackfillJob.perform_later(user.id)
    state
  end

  def self.cancel!(user)
    update!(user) do |current|
      current.empty? || current['status'] != 'running' ? current : current.merge('status' => 'cancelled')
    end
  end

  def self.oldest_date(user)
    feed_date = Gtfs::Matching::FeedSet.for_user(user).earliest_service_date
    first_ts = Point.where(user_id: user.id).minimum(:timestamp)
    return nil if feed_date.nil? || first_ts.nil?

    first_date = Time.zone.at(first_ts).in_time_zone(user.timezone_iana).to_date
    [feed_date, first_date].max
  end

  # Atomic read-modify-write of the state (row lock), so a cancel and a
  # running step never overwrite each other.
  def self.update!(user)
    Gtfs::UserState.update_json!(user, :backfill) do |current|
      next current if (changed = yield(current)).equal?(current)

      changed.merge('updated_at' => Time.current.iso8601)
    end
  end
end
