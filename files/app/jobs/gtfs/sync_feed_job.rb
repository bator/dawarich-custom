# frozen_string_literal: true

# Downloads one feed (conditional request) and imports it if it changed.
# Network errors are retried with backoff; on final failure the feed is marked
# failed and the previously imported version stays active.
#
# The HTTP cache validators (ETag/Last-Modified) are handed to the importer and
# only stored after a successful import, so a failed import is retried with a
# full download next time instead of being answered with 304 forever.
class Gtfs::SyncFeedJob < ApplicationJob
  queue_as :gtfs

  NETWORK_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
    Errno::ETIMEDOUT, SocketError, OpenSSL::SSL::SSLError, EOFError, Gtfs::FeedDownloader::HttpError
  ].freeze
  OTHER_ERROR_ATTEMPTS = 3

  # Handlers are matched last-declared-first: the specific ones below win over
  # this catch-all. Unexpected errors (disk full, DB down, ...) get a few
  # attempts instead of Sidekiq's default 25 retries over three weeks.
  retry_on(StandardError, wait: :polynomially_longer, attempts: OTHER_ERROR_ATTEMPTS) do |job, error|
    job.mark_failed(error)
  end
  retry_on(*NETWORK_ERRORS, wait: :polynomially_longer, attempts: 5) do |job, error|
    job.mark_failed(error)
  end
  # Deterministic failures: the importer already marked the feed failed and a
  # retry would process the same bytes again.
  discard_on Gtfs::FeedImporter::ImportError, Gtfs::ZipReader::Error do |_job, error|
    Rails.logger.warn("[GTFS] sync discarded: #{error.class}: #{error.message}")
  end
  # Another import of this feed is running; the next daily sync picks it up.
  discard_on Gtfs::FeedImporter::AlreadyRunning

  def perform(feed_id, force: false)
    feed = Gtfs::Feed.find_by(id: feed_id)
    return if feed.nil? || !feed.enabled?

    download = Gtfs::FeedDownloader.new(feed).call
    if download.status == :not_modified
      feed.update!(last_checked_at: Time.current)
      return
    end

    Gtfs::FeedImporter.new(feed, download.tempfile.path, force:, sha256: download.sha256,
                                                         etag: download.etag,
                                                         last_modified: download.last_modified).call
  rescue Gtfs::UrlGuard::Blocked, Gtfs::FeedDownloader::TooLarge, Gtfs::FeedDownloader::ConfigError => e
    # Configuration/safety problems: retrying cannot help.
    mark_failed(e)
  ensure
    download&.tempfile&.close!
  end

  def mark_failed(error)
    Gtfs::Feed.where(id: arguments.first).update_all(
      status: Gtfs::Feed.statuses[:failed],
      last_error: "#{error.class}: #{error.message}".truncate(2000),
      updated_at: Time.current
    )
    Rails.logger.warn("[GTFS] feed #{arguments.first} sync failed: #{error.class}: #{error.message}")
  end
end
