# frozen_string_literal: true

# Last live report per (user, device) for /transit/coverage. A device is a
# tracker_id (OwnTracks tid, the device_id of the Dawarich app, Overland or
# Traccar), resolved the way Points::SlimCollectionQuery does it: from
# point_sources when the point has a source_id, else from the legacy column.
# Imported points are left out, they are history, not reports.
#
# Speed: points have no index on the device, so the query reads every live
# point of the period (about 0.3 s for 7 days, 1.6 s for 30, 5 s for 90 on
# CT 139); the page caches the result.
class Gtfs::DeviceReports
  def initialize(user_ids, since:)
    @user_ids = user_ids
    @since = since.to_i
  end

  # Rows (string keys) newest first: user_id, tracker_id, points_count, topic,
  # timestamp, received_at, battery, city, country_name.
  #
  # One row per (user, tracker_id): point count and newest timestamp from a
  # GROUP BY, then the newest point itself from a LATERAL lookup at that
  # (user_id, timestamp) on index_points_on_user_id_timestamp_lonlat, instead
  # of sorting every live point of the period (DISTINCT ON + window count).
  def call
    return [] if @user_ids.empty?

    sql = <<~SQL.squish
      SELECT g.user_id, g.tracker_id, g.points_count,
             l.topic, l.timestamp, extract(epoch FROM l.created_at)::bigint AS received_at,
             l.battery, l.city, l.country_name
      FROM (
        SELECT p.user_id,
               CASE WHEN p.source_id IS NULL THEN p.tracker_id ELSE ps.tracker_id END AS tracker_id,
               count(*) AS points_count, max(p.timestamp) AS last_timestamp
        FROM points p
        LEFT JOIN point_sources ps ON ps.id = p.source_id
        WHERE p.user_id IN (:user_ids) AND p.import_id IS NULL AND p.timestamp >= :since
        GROUP BY 1, 2
      ) g
      CROSS JOIN LATERAL (
        SELECT CASE WHEN p.source_id IS NULL THEN p.topic ELSE ps.topic END AS topic,
               p.timestamp, p.created_at, p.battery, p.city, p.country_name
        FROM points p
        LEFT JOIN point_sources ps ON ps.id = p.source_id
        WHERE p.user_id = g.user_id AND p.timestamp = g.last_timestamp AND p.import_id IS NULL
          AND (CASE WHEN p.source_id IS NULL THEN p.tracker_id ELSE ps.tracker_id END) IS NOT DISTINCT FROM g.tracker_id
        ORDER BY p.created_at DESC
        LIMIT 1
      ) l
    SQL
    rows = ActiveRecord::Base.connection.select_all(
      ActiveRecord::Base.sanitize_sql_array([sql, { user_ids: @user_ids, since: @since }])
    ).to_a
    rows.sort_by { |row| -row['timestamp'].to_i }
  end
end
