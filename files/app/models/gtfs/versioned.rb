# frozen_string_literal: true

# Shared behaviour of the per-version GTFS data tables. Rows are written in
# bulk by Gtfs::FeedImporter (COPY), never through ActiveRecord callbacks.
module Gtfs::Versioned
  extend ActiveSupport::Concern

  included do
    belongs_to :feed, class_name: 'Gtfs::Feed'

    # Rows of the currently active import of each feed.
    scope :active, lambda {
      joins(:feed).where("#{table_name}.version = gtfs_feeds.active_version")
    }
    scope :for_version, ->(feed, version) { where(feed_id: feed.id, version:) }
  end
end
