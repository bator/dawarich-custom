# frozen_string_literal: true

# The timetable line of a ride for the track pick: Gtfs::Discord::RideMap (shape of the
# matched trip, else the stops, else straight; privacy zones clipped), plus one fallback.
# Older rides keep a feed version that has since been dropped (only the active and one
# backup timetable stay), and MÁV renumbers trips and routes between versions, so their
# shape is gone and RideMap draws a straight line. Stop ids stay, so the fallback takes
# the newest trip of the same feed that calls at the boarding stop and then at the
# alighting stop, and cuts its shape between the two stops (line_source 'shape-other').
class TrackPick::RideLine < Gtfs::Discord::RideMap
  # 'straight' is a guess, not a timetable line: never written as points
  USABLE = %w[shape shape-other stops].freeze

  private

  def line_coordinates
    source, coordinates = super
    return [source, coordinates] unless source == 'straight'

    other = other_trip_shape
    other.size >= 2 ? ['shape-other', other] : [source, coordinates]
  end

  def other_trip_shape
    board = lonlat(@segment.boarding_lonlat)
    alight = lonlat(@segment.alighting_lonlat)
    return [] unless board && alight && @segment.boarding_stop_gtfs_id && @segment.alighting_stop_gtfs_id

    sql = <<~SQL.squish
      WITH trip AS (
        SELECT t.feed_id, t.version, t.shape_gtfs_id
        FROM gtfs_trips t
        JOIN gtfs_stop_times a ON a.feed_id = t.feed_id AND a.version = t.version AND a.trip_gtfs_id = t.gtfs_id
                              AND a.stop_gtfs_id = ?
        JOIN gtfs_stop_times b ON b.feed_id = t.feed_id AND b.version = t.version AND b.trip_gtfs_id = t.gtfs_id
                              AND b.stop_gtfs_id = ? AND b.stop_sequence > a.stop_sequence
        JOIN gtfs_shapes s ON s.feed_id = t.feed_id AND s.version = t.version AND s.gtfs_id = t.shape_gtfs_id
        WHERE t.feed_id = ?
        ORDER BY t.version DESC, b.stop_sequence - a.stop_sequence
        LIMIT 1
      ), located AS (
        SELECT s.path::geometry AS g,
               ST_LineLocatePoint(s.path::geometry, ST_SetSRID(ST_MakePoint(?, ?), 4326)) AS a,
               ST_LineLocatePoint(s.path::geometry, ST_SetSRID(ST_MakePoint(?, ?), 4326)) AS b
        FROM trip JOIN gtfs_shapes s ON s.feed_id = trip.feed_id AND s.version = trip.version
                                    AND s.gtfs_id = trip.shape_gtfs_id
      )
      SELECT ST_AsGeoJSON(ST_LineSubstring(g, LEAST(a, b), GREATEST(a, b)), 6) FROM located WHERE a <> b
    SQL
    json = select_value(sql, @segment.boarding_stop_gtfs_id, @segment.alighting_stop_gtfs_id, @segment.feed_id,
                        *board, *alight)
    coords = json ? Array(JSON.parse(json)['coordinates']) : []
    # the shape runs alighting -> boarding when the stops were located the other way round
    coords.reverse! if coords.size >= 2 && dist2(coords.first, board) > dist2(coords.last, board)
    coords
  end

  def dist2((lon1, lat1), (lon2, lat2)) = ((lon1 - lon2)**2) + ((lat1 - lat2)**2)
end
