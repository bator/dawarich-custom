# frozen_string_literal: true

# Saves matcher results for one user and time range (spec 9.10). Only the
# derived tables transit_segments / transit_segment_points are written; points
# are read, never changed.
#
# - Idempotent: a result with the same (feed, trip, started_at) as an existing
#   `auto` segment updates it (same id); unchanged rows are not touched. A
#   second run over the same input therefore yields the same rows.
# - `auto` segments of the range that were not found again are removed, but
#   only for feeds that could actually be evaluated in the range. Rides from a
#   feed whose timetable is no longer available (decision K4: only active +
#   one backup version) are kept as they are.
# - `confirmed` and `rejected` segments, and `auto` segments the user switched
#   to another trip (chosen_by_user, waiting for approval), are never
#   modified, and no new segment is created that overlaps one of them.
class Gtfs::SegmentWriter
  class FeedChanged < StandardError; end

  CHOSEN_SQL = "(transit_segments.debug->>'chosen_by_user') IS NOT DISTINCT FROM 'true'"

  Summary = Struct.new(:created, :updated, :unchanged, :deleted, :skipped_protected, :cleaned, keyword_init: true)

  def initialize(user, feed_set:)
    @user = user
    @feed_set = feed_set
  end

  # evaluated_feed_ids: feeds whose old `auto` rides in the range may be replaced
  def call(matches, from_ts:, to_ts:, evaluated_feed_ids:)
    summary = Summary.new(created: 0, updated: 0, unchanged: 0, deleted: 0, skipped_protected: 0, cleaned: 0)
    TransitSegment.transaction do
      raise FeedChanged, 'a feed switched its timetable version during matching' unless @feed_set.unchanged?

      protected_ranges = protected_segments(from_ts, to_ts)
      existing = existing_auto(from_ts, to_ts, evaluated_feed_ids).index_by { |s| key_of(s) }
      kept_ids = []

      matches.each do |match|
        if protected_ranges.any? { |from, to| overlap?(match, from, to) }
          summary.skipped_protected += 1
          next
        end

        attributes = Gtfs::SegmentAttributes.new(match).to_h
        segment = existing[[attributes[:feed_id], attributes[:trip_gtfs_id], attributes[:started_at]]]
        segment ||= existing_with_key(attributes)
        if segment&.reviewed? # same key as a confirmed/rejected/switched ride (review A3)
          summary.skipped_protected += 1
          next
        end

        kept_ids << save(segment, attributes, match.score.point_ids, summary)
      end

      stale = existing.values.reject { |s| kept_ids.include?(s.id) }
      summary.deleted = stale.size
      TransitSegment.where(id: stale.map(&:id)).delete_all if stale.any?
    end
    summary
  end

  private

  def protected_segments(from_ts, to_ts)
    reviewed = @user.transit_segments.where(status: %i[confirmed rejected])
                    .or(@user.transit_segments.where(CHOSEN_SQL))
    reviewed.where('started_at < ? AND ended_at > ?', to_ts + Gtfs::Config::DAY_BUFFER_SECS,
                   from_ts - Gtfs::Config::DAY_BUFFER_SECS)
            .pluck(:started_at, :ended_at)
  end

  def existing_auto(from_ts, to_ts, feed_ids)
    @user.transit_segments.auto.where.not(CHOSEN_SQL).where(started_at: from_ts...to_ts, feed_id: feed_ids).to_a
  end

  # A row with the same unique key but outside the replaced range/feeds (e.g.
  # started exactly at the boundary): an auto row is reused, a protected one
  # blocks the match, instead of failing on the unique index.
  def existing_with_key(attributes)
    @user.transit_segments.find_by(feed_id: attributes[:feed_id], trip_gtfs_id: attributes[:trip_gtfs_id],
                                   started_at: attributes[:started_at])
  end

  def key_of(segment)
    [segment.feed_id, segment.trip_gtfs_id, segment.started_at]
  end

  def overlap?(match, from, to)
    [match.ended_at, to].min - [match.started_at, from].max > Gtfs::SegmentMatcher::OVERLAP_SECS
  end

  def save(segment, attributes, point_ids, summary)
    if segment.nil?
      segment = @user.transit_segments.create!(attributes.merge(status: :auto))
      summary.created += 1
    else
      segment.assign_attributes(attributes)
      if segment.changed?
        segment.save!
        summary.updated += 1
      else
        summary.unchanged += 1
      end
    end
    link_points(segment, point_ids)
    segment.id
  end

  def link_points(segment, point_ids)
    current = segment.transit_segment_points.pluck(:point_id)
    return if current.sort == point_ids.sort

    segment.transit_segment_points.where.not(point_id: point_ids).delete_all
    missing = point_ids - current
    return if missing.empty?

    now = Time.current
    TransitSegmentPoint.insert_all(
      missing.map { |id| { transit_segment_id: segment.id, point_id: id, created_at: now, updated_at: now } },
      unique_by: %i[transit_segment_id point_id]
    )
  end
end
