# frozen_string_literal: true

# Matches and saves one day of one user (spec 9.10). Runs on the gtfs queue;
# only `auto` segments are replaced (Gtfs::SegmentWriter).
#
# Every day is its own job (review K4): a failing day is retried on its own
# (3 attempts) and never holds up the other days. When it finally fails - or
# stays busy after MAX_BUSY_RETRIES - the failure is written to
# gtfs_user_states.last_match and the admins get a notification, instead of
# the day being dropped silently.
#
# Jobs are enqueued through enqueue_days, which skips a (user, day) that is
# already waiting in the queue (review K5: several feed imports in one night
# rematch the same days only once). The job loads the timetables when it
# runs, so one run covers every import that happened before it.
class Gtfs::MatchUserDaysJob < ApplicationJob
  queue_as :gtfs

  BUSY_RETRY_WAIT = 2.minutes
  MAX_BUSY_RETRIES = 5
  PENDING_TTL = 6.hours # a lost job blocks re-enqueueing its day at most this long
  FAILURE_TITLE = 'GTFS matching failed'

  # (last declared is checked first)
  retry_on StandardError, wait: 5.minutes, attempts: 3 do |job, error|
    job.record_failure!(error)
  end
  retry_on Gtfs::SegmentWriter::FeedChanged, wait: 1.minute, attempts: 3 do |job, error|
    job.record_failure!(error)
  end

  # => the dates that were enqueued (the others are already pending); the
  # jobs are appended to `jobs` when given (API: job ids)
  def self.enqueue_days(user_id, dates, jobs: nil)
    dates.select do |date|
      next false unless Rails.cache.write(pending_key(user_id, date), true, unless_exist: true,
                                                                             expires_in: PENDING_TTL)

      job = perform_later(user_id, date.iso8601)
      jobs&.push(job)
      true
    end
  end

  def self.pending_key(user_id, date)
    "gtfs:match_pending:#{user_id}:#{date.to_date.iso8601}"
  end

  # to_date: jobs enqueued by 91805a3 carried a range; its other days are
  # enqueued as jobs of their own.
  def perform(user_id, date, to_date = nil, busy_retries: 0)
    date = Date.parse(date.to_s)
    Rails.cache.delete(self.class.pending_key(user_id, date)) # from now on a new enqueue is a new run
    return unless Gtfs.enabled?

    user = find_user_or_skip(user_id) || return
    return unless Gtfs::UserSettings.new(user).enabled?

    self.class.enqueue_days(user_id, (date + 1)..Date.parse(to_date.to_s)) if to_date.present?
    run(user, date, busy_retries)
  end

  def record_failure!(error)
    user_id, date = arguments
    message = "#{error.class}: #{error.message}".truncate(300)
    Rails.logger.error("[GTFS match] user #{user_id} #{date}: giving up: #{message}")
    user = User.find_by(id: user_id)
    return unless user

    Gtfs::UserState.update_json!(user, :last_match) do
      { 'date' => date.to_s, 'status' => 'failed', 'error' => message, 'at' => Time.current.iso8601 }
    end
    notify_admins("User #{user_id}, day #{date}: #{message}")
  end

  private

  def run(user, date, busy_retries)
    outcome = Gtfs::MatchDay.new(user, date).call
    Gtfs::UserState.update_json!(user, :last_match) do
      { 'date' => date.iso8601, 'status' => 'ok', 'matches' => outcome.matches.size, 'at' => Time.current.iso8601 }
    end
    Gtfs::Discord::NotifyJob.perform_later(user.id) if Gtfs::Discord::Config.enabled_for?(user)
    Gtfs::Discord::MessageCleanupJob.perform_later(user.id) if Gtfs::Discord::Config.enabled?
  rescue Gtfs::MatchDay::Busy => e
    return record_failure!(e) if busy_retries >= MAX_BUSY_RETRIES

    self.class.set(wait: BUSY_RETRY_WAIT).perform_later(user.id, date.iso8601, busy_retries: busy_retries + 1)
  end

  def notify_admins(content)
    User.where(admin: true).find_each do |admin|
      next if Notification.exists?(user: admin, title: FAILURE_TITLE, content:)

      Notification.create!(user: admin, kind: :warning, title: FAILURE_TITLE, content:)
    end
  rescue StandardError => e
    Rails.logger.error("[GTFS match] could not notify admins: #{e.class}: #{e.message}")
  end
end
