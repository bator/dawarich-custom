# frozen_string_literal: true

# Keeps the transport modes users set by hand (Tracks::SegmentEditor: a
# segment with corrected_at and source 'user') across track rebuilds. A bulk
# rebuild (Tracks::ParallelGenerator in bulk mode, run by TrackPick::Hider and
# AccuracyGate) deletes the tracks with their segments; on 2026-10-24 user 2
# lost 45 corrections that way (recovered from the PBS backup).
#
# - capture!: every hand-set segment is stored as a TrackModeCorrection (its
#   time span and mode). A stored correction whose segments still sit on the
#   tracks it was taken from, but none of them corrected any more, was reset
#   by the user and is dropped.
# - restore!: a stored correction is written back onto the segments of tracks
#   built after it was captured that lie mostly (MIN_SHARE) inside its span and
#   are not set by hand: corrected_at = its capture time, source 'user'.
#
# Run by Gtfs::TrackModesJob before the timetable modes (Gtfs::TrackModes), so
# a hand-set mode wins over a ride's.
class TrackModeCorrections
  MIN_SHARE = 0.5
  SOURCE = 'user'

  def initialize(user)
    @user = user
  end

  # => [captured, dropped]
  def capture!
    now = Time.current
    captured = 0
    hand_set.each do |segment|
      row = TrackModeCorrection.find_or_initialize_by(user_id: @user.id, start_at: segment.start_at,
                                                      end_at: segment.end_at)
      next if row.persisted? && row.transportation_mode == segment.transportation_mode

      row.update!(transportation_mode: segment.transportation_mode, captured_at: now)
      captured += 1
    end
    [captured, drop_reset]
  end

  # => number of segments written back
  def restore!
    written = 0
    touched = []
    TrackModeCorrection.where(user_id: @user.id).find_each do |row|
      targets(row).each do |segment|
        TrackSegment.where(id: segment.id).update_all(
          transportation_mode: TrackSegment.transportation_modes[row.transportation_mode],
          corrected_at: row.captured_at, source: SOURCE, confidence: TrackSegment.confidences[:high],
          confidence_score: 1.0, updated_at: Time.current
        )
        touched << segment.track_id
        written += 1
      end
    end
    refresh_tracks(touched.uniq)
    written
  end

  private

  def segments
    TrackSegment.joins(:track).where(tracks: { user_id: @user.id }).where.not(start_at: nil).where.not(end_at: nil)
  end

  def hand_set
    segments.where.not(corrected_at: nil).where(source: SOURCE)
  end

  def overlapping(row)
    segments.where('track_segments.start_at < ? AND track_segments.end_at > ?', row.end_at, row.start_at)
  end

  # segments of tracks built after the capture, mostly inside the span, not set by hand
  def targets(row)
    overlapping(row).where('tracks.created_at > ?', row.captured_at)
                    .where('track_segments.corrected_at IS NULL OR track_segments.source <> ?', SOURCE)
                    .select { |s| share(s, row) >= MIN_SHARE }
  end

  def share(segment, row)
    span = segment.end_at - segment.start_at
    return 0 unless span.positive?

    ([segment.end_at, row.end_at].min - [segment.start_at, row.start_at].max).clamp(0, span) / span
  end

  # reset by the user: the original tracks are still there, nothing in the span is hand-set
  def drop_reset
    dropped = 0
    TrackModeCorrection.where(user_id: @user.id).find_each do |row|
      old = overlapping(row).where('tracks.created_at <= ?', row.captured_at).select { |s| share(s, row) >= MIN_SHARE }
      next if old.empty? || old.any? { |s| s.corrected_at && s.source == SOURCE }

      row.destroy!
      dropped += 1
    end
    dropped
  end

  def refresh_tracks(track_ids)
    Track.where(id: track_ids).find_each do |track|
      mode = Track.pick_dominant_mode(track.track_segments.reload.to_a)
      track.update!(dominant_mode: mode) if mode && track.dominant_mode != mode.to_s
      Tracks::TileEpoch.bump(@user.id, timestamps: [track.start_at.to_i, track.end_at.to_i])
    end
  end
end
