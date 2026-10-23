# frozen_string_literal: true

# Confirm / reject / undo a transit segment, or replace it with one of its
# alternatives ("another trip", spec 12.3). The one code path for the web
# list, the map popup, the API and the Discord buttons.
#
# A segment is looked up with TransitSegment.reviewable_for, so only the
# user's own rides that are not hidden by privacy rules can be changed. An
# `auto` ride can disappear or get a new id when its day is matched again
# (review A2); such an id raises NotFound and the caller must reload.
class Gtfs::SegmentReview
  class NotFound < StandardError; end
  class Invalid < StandardError; end

  ACTIONS = %w[confirm reject reset choose].freeze
  STATUS_FOR = { 'confirm' => :confirmed, 'reject' => :rejected, 'reset' => :auto }.freeze
  SOURCES = %w[web api discord].freeze

  def initialize(user, source:)
    raise ArgumentError, "unknown source #{source}" unless SOURCES.include?(source.to_s)

    @user = user
    @source = source.to_s
  end

  def find(id)
    TransitSegment.reviewable_for(@user).find_by(id:) || raise(NotFound, "transit segment #{id} not found")
  end

  # => the updated segment
  def call(id, action, trip_gtfs_id: nil, feed_id: nil)
    action = action.to_s
    raise Invalid, "unknown action #{action}" unless ACTIONS.include?(action)

    segment = find(id)
    changed = segment.with_lock do
      action == 'choose' ? choose!(segment, trip_gtfs_id, feed_id) : set_status!(segment, STATUS_FOR.fetch(action))
    end
    if changed
      sync_discord(segment)
      Gtfs::TrackModesJob.perform_later(segment.user_id) # the track's mode follows the review
    end
    segment
  end

  private

  def set_status!(segment, status)
    return false if segment.status == status.to_s

    segment.update!(status:, debug: with_review(segment.debug, status))
    true
  end

  # The alternative becomes the segment (same row, so links and the Discord
  # message stay); the old trip becomes an alternative. The ride is NOT
  # approved by this: it is `auto` again (waiting for approval, marked
  # chosen_by_user so rematching keeps it) until it is confirmed or rejected.
  def choose!(segment, trip_gtfs_id, feed_id)
    debug = segment.debug || {}
    list = Array(debug['alternatives']) + Array(debug['trip_alternatives'])
    alt = list.find { |a| a['trip_gtfs_id'] == trip_gtfs_id && (feed_id.blank? || a['feed_id'].to_s == feed_id.to_s) }
    raise Invalid, 'not an alternative of this ride' unless alt
    raise Invalid, 'alternative from an older matcher run; match the day again' unless alt.key?('started_at')

    columns = alt.slice(*Gtfs::SegmentAttributes::TRIP_COLUMNS, 'boarding_lonlat', 'alighting_lonlat')
    clash = TransitSegment.where(user_id: segment.user_id, feed_id: columns['feed_id'],
                                 trip_gtfs_id: columns['trip_gtfs_id'], started_at: columns['started_at'])
                          .where.not(id: segment.id)
    raise Invalid, 'this trip is already saved as another ride' if clash.exists?

    segment.update!(columns.merge('status' => :auto, 'confidence' => alt['confidence'],
                                  'debug' => swapped_debug(segment, debug, alt)))
    true
  end

  def swapped_debug(segment, debug, alt)
    previous = {
      'feed_id' => segment.feed_id, 'trip_gtfs_id' => segment.trip_gtfs_id, 'line' => segment.route_short_name,
      'confidence' => segment.confidence
    }.merge(segment.attributes.slice(*Gtfs::SegmentAttributes::TRIP_COLUMNS))
    previous['boarding_lonlat'] = segment.boarding_lonlat&.as_text
    previous['alighting_lonlat'] = segment.alighting_lonlat&.as_text
    previous.merge!(debug.slice('service_date', 'scheduled_departure_secs', 'scheduled_arrival_secs', 'delay_secs'))

    key = ->(a) { [a['feed_id'].to_s, a['trip_gtfs_id']] }
    alternatives = [previous] + Array(debug['alternatives']).reject { |a| key[a] == key[alt] }
    trip_alternatives = Array(debug['trip_alternatives']).reject { |a| key[a] == key[alt] }
    # The scorer's caps (no intermediate stop, no dwell) belong to the old
    # trip; cleared with the ambiguity flags so the ride shows as "chosen",
    # not "uncertain", until the user approves it.
    merged = debug.merge(alt.slice('service_date', 'scheduled_departure_secs', 'scheduled_arrival_secs', 'delay_secs'))
                  .merge('alternatives' => alternatives, 'trip_alternatives' => trip_alternatives,
                         'ambiguous' => false, 'trip_ambiguous' => false, 'caps' => [], 'chosen_by_user' => true)
    with_review(merged, :auto).tap { |d| d['review']['action'] = 'choose' }
  end

  def with_review(debug, status)
    (debug || {}).merge('review' => { 'status' => status.to_s, 'source' => @source, 'at' => Time.current.iso8601 })
  end

  # A change made on the web or through the API also updates the Discord
  # message of the ride (the Discord path edits it itself).
  def sync_discord(segment)
    return if @source == 'discord' || !Gtfs::Discord::Config.enabled?

    Gtfs::Discord::SyncMessageJob.perform_later(segment.id)
  end
end
