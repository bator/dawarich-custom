# frozen_string_literal: true

# Turns a matcher result into transit_segments attributes. Names and line data
# are copied into the row, so a segment stays readable after its timetable
# version has been removed (decision K4).
class Gtfs::SegmentAttributes
  MATCHER_VERSION = 3 # 3: alternatives carry what "choose another trip" needs (Phase 3)

  # Columns an alternative can replace when the user picks it (Phase 3).
  TRIP_COLUMNS = %w[feed_id feed_version route_gtfs_id trip_gtfs_id route_short_name route_long_name route_type
                    headsign boarding_stop_gtfs_id boarding_stop_name alighting_stop_gtfs_id alighting_stop_name
                    started_at ended_at distance_m].freeze

  def initialize(match)
    @match = match
    @score = match.score
    @candidate = @score.candidate
    @profile = @score.profile
  end

  def to_h
    trip_columns(@score).merge(
      confidence: @score.confidence,
      point_count: @score.point_ids.size,
      debug:
    )
  end

  private

  def trip_columns(score)
    profile = score.profile
    candidate = score.candidate
    {
      feed_id: candidate.feed.id,
      feed_version: candidate.version,
      route_gtfs_id: profile.trip.route_gtfs_id,
      trip_gtfs_id: profile.trip.gtfs_id,
      route_short_name: profile.line_name,
      route_long_name: profile.route&.long_name,
      route_type: profile.route&.route_type,
      headsign: profile.trip.headsign,
      boarding_stop_gtfs_id: score.board.stop_gtfs_id,
      boarding_stop_name: profile.display_name(score.board),
      boarding_lonlat: point_wkt(score.board),
      alighting_stop_gtfs_id: score.alight.stop_gtfs_id,
      alighting_stop_name: profile.display_name(score.alight),
      alighting_lonlat: point_wkt(score.alight),
      started_at: score.started_at,
      ended_at: score.ended_at,
      distance_m: score.distance_m
    }
  end

  def point_wkt(call)
    "POINT(#{call.lon} #{call.lat})"
  end

  def debug
    {
      'matcher_version' => MATCHER_VERSION,
      'service_date' => @candidate.service_date.iso8601,
      'version_role' => @candidate.version == @candidate.feed.active_version ? 'active' : 'backup',
      'scheduled_departure_secs' => @score.board.departure_secs,
      'scheduled_arrival_secs' => @score.alight.arrival_secs,
      'delay_secs' => @score.delay_secs,
      'features' => @score.features.transform_keys(&:to_s),
      'shape_source' => @profile.shape_source,
      'window_kind' => @match.window_kind.to_s,
      'gps_gap' => @score.gap_mode,
      'uncertain' => uncertain?,
      'ambiguous' => @match.ambiguous,
      'trip_ambiguous' => @match.trip_ambiguous == true,
      'caps' => Array(@score.caps),
      'alternatives' => @match.alternatives.map { |alt| alternative(alt) },
      'trip_alternatives' => Array(@match.trip_alternatives).map { |alt| alternative(alt) }
    }
  end

  def uncertain?
    @match.ambiguous || @match.trip_ambiguous == true || Array(@score.caps).any? ||
      @score.confidence < Gtfs::Config::AUTO_ACCEPT
  end

  # Everything needed to show the alternative and, if the user picks it, to
  # turn the segment into it (Gtfs::SegmentReview#choose!).
  def alternative(score)
    trip_columns(score).transform_keys(&:to_s).merge(
      'line' => score.profile.line_name,
      'confidence' => score.confidence,
      'service_date' => score.candidate.service_date.iso8601,
      'scheduled_departure_secs' => score.board.departure_secs,
      'scheduled_arrival_secs' => score.alight.arrival_secs,
      'delay_secs' => score.delay_secs
    )
  end
end
