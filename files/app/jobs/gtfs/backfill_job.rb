# frozen_string_literal: true

# One step of Gtfs::Backfill: matches the day at the cursor, moves the cursor
# to the previous day that has points, and enqueues itself again. Stops when
# the state is no longer `running` (cancelled) or the oldest matchable day is
# done. A lost job can be resumed with Gtfs::Backfill.start! (rake gtfs:backfill).
class Gtfs::BackfillJob < ApplicationJob
  queue_as :gtfs

  BUSY_RETRY_WAIT = 2.minutes

  def perform(user_id)
    return unless Gtfs.enabled?

    user = find_user_or_skip(user_id) || return
    state = Gtfs::Backfill.status(user)
    return unless state['status'] == 'running' && Gtfs::UserSettings.new(user).enabled?

    cursor = state['cursor'] && Date.parse(state['cursor'])
    oldest = state['until'] && Date.parse(state['until'])
    return finish!(user) if cursor.nil? || oldest.nil? || cursor < oldest

    begin
      Gtfs::MatchDay.new(user, cursor).call
    rescue Gtfs::MatchDay::Busy
      return self.class.set(wait: BUSY_RETRY_WAIT).perform_later(user_id)
    end

    following = previous_day_with_points(user, cursor)
    # re-read under the lock: the backfill may have been cancelled meanwhile
    state = Gtfs::Backfill.update!(user) do |current|
      current.merge('days_done' => current['days_done'].to_i + 1, 'cursor' => following&.iso8601)
    end
    return finish!(user) if following.nil? || following < oldest
    return unless state['status'] == 'running'

    self.class.perform_later(user_id)
  end

  private

  def previous_day_with_points(user, date)
    from_ts, = Gtfs::MatchDay.day_range(user, date)
    ts = Point.where(user_id: user.id).where(timestamp: ...from_ts).maximum(:timestamp)
    ts && Time.zone.at(ts).in_time_zone(user.timezone_iana).to_date
  end

  def finish!(user)
    Gtfs::Backfill.update!(user) do |current|
      next current if current['status'] == 'cancelled'

      current.merge('status' => 'done', 'cursor' => nil, 'finished_at' => Time.current.iso8601)
    end
  end
end
