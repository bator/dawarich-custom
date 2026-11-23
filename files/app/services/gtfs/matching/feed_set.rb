# frozen_string_literal: true

# The feeds (and timetable versions) one matcher run works with.
#
# Decision K4: per feed only the active version and ONE backup (the
# previously active version) exist. A day is matched against the active
# version when it has service days for that date, otherwise against the
# backup. Older dates cannot be matched any more, which is why the daily
# match job runs before the next feed update (docs/gtfs.md).
#
# The versions are read once when the run starts and used for the whole run
# (spec 17.11); SegmentWriter refuses to save if a feed changed meanwhile.
class Gtfs::Matching::FeedSet
  Entry = Struct.new(:feed, :versions, :base_id, keyword_init: true) # base_id: archive feeds (archive_of)

  attr_reader :entries

  # feed_keys: optional allow-list (user setting gtfs_feed_keys)
  def self.for_user(user, feed_keys: Gtfs::UserSettings.new(user).feed_keys)
    scope = Gtfs::Feed.enabled.where('active_version > 0')
    scope = scope.where(key: feed_keys) if feed_keys.present?
    feeds = scope.order(:id).to_a
    new(feeds + archives_of(feeds), user:)
  end

  # Disabled archive feeds (config archive_of) of the feeds in use, with an imported version.
  def self.archives_of(feeds)
    keys = feeds.map(&:key)
    archive_keys = Gtfs::FeedRegistry.definitions.select { |_, d| keys.include?(d['archive_of'].to_s) }.keys
    return [] if archive_keys.empty?

    Gtfs::Feed.where(key: archive_keys).where('active_version > 0').order(:id).to_a
  end

  def initialize(feeds, user: nil)
    by_key = feeds.index_by(&:key)
    @user = user
    @entries = feeds.map do |feed|
      base = by_key[Gtfs::FeedRegistry.definition(feed.key)&.dig('archive_of').to_s]
      Entry.new(feed:, versions: versions_of(feed), base_id: base&.id)
    end
    @coverage = {}
  end

  delegate :empty?, to: :@entries

  def feeds = @entries.map(&:feed)

  # Version of `feed` that has service days on `date` (active first), or nil.
  def version_for(feed, date)
    entry = @entries.find { |e| e.feed.id == feed.id }
    return nil unless entry

    # an archive only fills the days its base feed has no timetable for (no duplicate trips), and
    # never a day the base feed matched for this user while it had one: those rides came from the
    # real timetable and an archive ride would sit next to them (2026-11-23: the night rematch
    # after a budapest import doubled user 8's rides of 11-17..11-21)
    if entry.base_id
      base = @entries.find { |e| e.feed.id == entry.base_id }
      return nil if base && version_for(base.feed, date)
      return nil if base_matched_dates(entry.base_id).include?(date)
    end

    entry.versions.find { |version| covers?(feed.id, version, date) }
  end

  # { feed_id => version } of the feeds that can be matched on `date`.
  def covering(date)
    @entries.each_with_object({}) do |entry, memo|
      version = version_for(entry.feed, date)
      memo[entry.feed.id] = version if version
    end
  end

  def role(feed, version)
    version == feed.active_version ? 'active' : 'backup'
  end

  # Earliest date any version of these feeds can still match (backfill stop).
  def earliest_service_date
    return nil if empty?

    Gtfs::ServiceDay.where(feed_id: @entries.map { |e| e.feed.id })
                    .where(version: @entries.flat_map(&:versions)).minimum(:service_date)
  end

  # True when no feed switched its active version since this set was built.
  def unchanged?
    current = Gtfs::Feed.where(id: @entries.map { |e| e.feed.id }).pluck(:id, :active_version).to_h
    @entries.all? { |e| current[e.feed.id] == e.feed.active_version }
  end

  private

  def versions_of(feed)
    backup = Gtfs::ServiceDay.where(feed_id: feed.id).where(version: ...feed.active_version)
                             .distinct.pluck(:version).max
    [feed.active_version, backup].compact
  end

  # local dates on which the user has rides of the base feed (any status)
  def base_matched_dates(base_id)
    return Set.new unless @user

    @base_matched ||= {}
    @base_matched[base_id] ||= begin
      zone = ActiveSupport::TimeZone[@user.timezone_iana.to_s] || Time.zone
      TransitSegment.where(user_id: @user.id, feed_id: base_id).pluck(:started_at)
                    .to_set { |ts| Time.zone.at(ts).in_time_zone(zone).to_date }
    end
  end

  def covers?(feed_id, version, date)
    @coverage.fetch([feed_id, version, date]) do
      @coverage[[feed_id, version, date]] =
        Gtfs::ServiceDay.exists?(feed_id:, version:, service_date: date)
    end
  end
end
