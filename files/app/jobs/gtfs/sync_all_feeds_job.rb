# frozen_string_literal: true

# Daily (config/schedule.yml): refresh feed definitions, enqueue one sync per
# enabled feed and warn admins about expired/expiring timetables.
# No-op unless GTFS_ENABLED=true.
class Gtfs::SyncAllFeedsJob < ApplicationJob
  queue_as :gtfs

  def perform
    return unless Gtfs.enabled?

    removed = Gtfs.cleanup_tmp_dir!
    Rails.logger.info("[GTFS] removed #{removed} stale temp file(s)") if removed.positive?
    Gtfs::FeedRegistry.seed!
    Gtfs::Feed.enabled.where.not(source_url: [nil, '']).find_each do |feed|
      Gtfs::SyncFeedJob.perform_later(feed.id)
    end
    Gtfs::ExpiryCheck.notify_admins!
  end
end
