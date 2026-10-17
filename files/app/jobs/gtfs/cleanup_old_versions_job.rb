# frozen_string_literal: true

# Removes superseded GTFS versions in batches. Retention (decision K4): the
# active version plus exactly one backup (the previously active version).
# Successful imports already apply this themselves; this job is the safety
# net (purge errors, interrupted imports) and backs `gtfs:cleanup`.
#
# Decisions are made with the feed's advisory lock held and on freshly loaded
# state: an import of the same feed cannot run in parallel, and a feed left in
# "importing" by a killed process is recognised as interrupted (the lock is
# free) and its partial version is removed.
class Gtfs::CleanupOldVersionsJob < ApplicationJob
  queue_as :gtfs

  LOCK_BUSY_RETRY_WAIT = 10.minutes
  MAX_LOCK_BUSY_RETRIES = 6

  def perform(feed_id, lock_busy_retries: 0)
    feed = Gtfs::Feed.find_by(id: feed_id)
    return if feed.nil?

    lock = ActiveRecord::Base.with_advisory_lock_result(feed.advisory_lock_name, timeout_seconds: 0) do
      cleanup!(feed.reload)
    end
    return if lock.lock_was_acquired?
    return if lock_busy_retries >= MAX_LOCK_BUSY_RETRIES

    # An import of this feed is running; it applies the retention rule itself
    # when it succeeds, this retry only covers the case where that import dies.
    self.class.set(wait: LOCK_BUSY_RETRY_WAIT).perform_later(feed_id, lock_busy_retries: lock_busy_retries + 1)
  end

  private

  def cleanup!(feed)
    if feed.importing?
      Rails.logger.warn("[GTFS #{feed.key}] import was interrupted (status importing, lock free); cleaning up")
      feed.update!(status: :failed, last_error: 'import was interrupted (process killed?); partial data removed')
    end

    # (active_version 0 = never imported: every stored version is a leftover)
    Gtfs::VersionPurger.retain_active_and_backup!(feed.id, feed.active_version)
  end
end
