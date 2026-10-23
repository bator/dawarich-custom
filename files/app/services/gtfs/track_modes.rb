# frozen_string_literal: true

# The transport mode of the track segments under a confirmed ride: Dawarich
# guesses a segment's mode from speed alone (TransportationModes::Detector),
# so a train ride on the M7 corridor came out as `driving` (Z30
# Kelenföld - Székesfehérvár, 2026-10-22; Bator: the confirmed ride must say
# train on the map). A segment whose time lies mostly (MIN_SHARE) inside the
# user's confirmed rides gets the ride's mode (MODE_FOR), marked like a manual
# correction (corrected_at), so Tracks::Reprocessor and a track rebuild of the
# same track keep it, with source SOURCE.
#
# - A segment the user corrected by hand (corrected_at, another source) is
#   never touched.
# - A segment set by us whose ride is no longer confirmed (rejected, reset)
#   goes back to detection: corrected_at cleared, the track reprocessed.
# - Segments without times (anchored by point indexes only) are left alone.
#
# Rebuilt tracks (a TrackPick pick rebuilds the day) come back with detected
# modes; Gtfs::TrackModesJob runs every few minutes over the recent days and
# after each review, so they are set again.
class Gtfs::TrackModes
  SOURCE = 'gtfs'
  MIN_SHARE = 0.5
  # TransitSegment#mode => Track::TRANSPORTATION_MODES (it has no tram or metro)
  MODE_FOR = { 'rail' => 'train', 'suburban' => 'train', 'metro' => 'train', 'tram' => 'train',
               'bus' => 'bus', 'ferry' => 'boat' }.freeze

  Change = Struct.new(:segment_id, :track_id, :from, :to, :ride_id, keyword_init: true)

  # from / to: epoch seconds
  def initialize(user, from:, to:)
    @user = user
    @from = from.to_i
    @to = to.to_i
  end

  # => [Change, ...] (what was or, with dry_run, would be changed)
  def call(dry_run: false)
    changes = segments.filter_map { |segment| change_for(segment) }
    apply(changes) unless dry_run
    changes
  end

  private

  def rides
    @rides ||= TransitSegment.where(user_id: @user.id, status: :confirmed)
                             .where('started_at < ? AND ended_at > ?', @to, @from).to_a
                             .filter_map { |r| (mode = MODE_FOR[r.mode]) && [r.id, r.started_at, r.ended_at, mode] }
  end

  def segments
    TrackSegment.joins(:track).where(tracks: { user_id: @user.id })
                .where.not(start_at: nil).where.not(end_at: nil)
                .where('track_segments.start_at < ? AND track_segments.end_at > ?', Time.zone.at(@to), Time.zone.at(@from))
                .to_a
  end

  def change_for(segment)
    return if segment.manually_corrected? && segment.source != SOURCE

    ride = ride_for(segment)
    if ride
      id, _, _, mode = ride
      return if segment.source == SOURCE && segment.transportation_mode == mode

      Change.new(segment_id: segment.id, track_id: segment.track_id, from: segment.transportation_mode, to: mode, ride_id: id)
    elsif segment.source == SOURCE
      Change.new(segment_id: segment.id, track_id: segment.track_id, from: segment.transportation_mode, to: nil)
    end
  end

  # the confirmed ride covering most of the segment, if it covers MIN_SHARE of it
  def ride_for(segment)
    s = segment.start_at.to_i
    e = segment.end_at.to_i
    return if e <= s

    best = rides.max_by { |_, rs, re, _| overlap(s, e, rs, re) }
    best if best && overlap(s, e, best[1], best[2]) >= MIN_SHARE * (e - s)
  end

  def overlap(start1, end1, start2, end2) = [[end1, end2].min - [start1, start2].max, 0].max

  def apply(changes)
    return if changes.empty?

    reset = []
    Track.transaction do
      changes.each do |c|
        if c.to
          TrackSegment.where(id: c.segment_id).update_all(transportation_mode: TrackSegment.transportation_modes[c.to],
                                                          corrected_at: Time.current, source: SOURCE,
                                                          confidence: TrackSegment.confidences[:high],
                                                          confidence_score: 1.0, updated_at: Time.current)
        else
          TrackSegment.where(id: c.segment_id).update_all(corrected_at: nil, source: 'inferred', updated_at: Time.current)
          reset << c.track_id
        end
      end
    end
    Track.where(id: changes.map(&:track_id).uniq).find_each do |track|
      if reset.include?(track.id)
        Tracks::Reprocessor.reprocess(track)
      else
        mode = Track.pick_dominant_mode(track.track_segments.reload.to_a)
        track.update!(dominant_mode: mode) if mode && track.dominant_mode != mode.to_s
      end
      Tracks::TileEpoch.bump(@user.id, timestamps: [track.start_at.to_i, track.end_at.to_i])
    end
  end
end
