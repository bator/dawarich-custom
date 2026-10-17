# frozen_string_literal: true

# Enqueued by Gtfs::FeedImporter after a successful import (spec 9.10: a new
# feed version may change earlier `auto` results). Rematches the last
# GTFS_REMATCH_DAYS days that the feed covers, for every opted-in user who
# matches against this feed, one job per day. Days that are already waiting
# in the queue are not enqueued again (review K5), so a night with many feed
# imports rematches each day once. Confirmed/rejected segments are never
# touched.
class Gtfs::RematchAfterImportJob < ApplicationJob
  queue_as :gtfs

  def perform(feed_id)
    return unless Gtfs.enabled?

    feed = Gtfs::Feed.find_by(id: feed_id)
    return if feed.nil? || !feed.enabled? || !feed.imported?

    Gtfs::UserSettings.opted_in_users.find_each do |user|
      feed_set = Gtfs::Matching::FeedSet.for_user(user)
      next unless feed_set.feeds.any? { |f| f.id == feed.id }

      today = Gtfs::MatchDay.today_for(user)
      dates = ((today - Gtfs::Config::REMATCH_DAYS)..(today - 1)).select do |date|
        feed_set.version_for(feed, date)
      end
      Gtfs::MatchUserDaysJob.enqueue_days(user.id, dates)
    end
  end
end
