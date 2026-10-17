# frozen_string_literal: true

# /transit/devices: when each person's devices last reported a live point.
# A device is a tracker_id (OwnTracks tid, the device_id of the Dawarich app,
# Overland or Traccar), resolved the way Points::SlimCollectionQuery does it:
# from point_sources when the point has a source_id, else from the legacy
# column. Imported points are left out, they are history, not reports.
# Admins see every user, everyone else only their own devices.
class TransitDevicesController < ApplicationController
  PERIODS = [1, 7, 30, 90].freeze
  # Badge thresholds of the last report.
  FRESH = 15.minutes
  STALE = 24.hours

  before_action :authenticate_user!

  def index
    @days = PERIODS.include?(params[:days].to_i) ? params[:days].to_i : 30
    @zone = ActiveSupport::TimeZone[current_user.timezone_iana] || Time.zone
    users = current_user.admin? ? User.all.to_a : [current_user]
    devices = last_reports(users.map(&:id), @days.days.ago.to_i).group_by { |row| row['user_id'] }
    @people = users.map { |user| [user, devices.fetch(user.id, [])] }
                   .sort_by { |user, rows| [rows.empty? ? 1 : 0, -(rows.first&.dig('timestamp') || 0), user.display_name.downcase] }
  end

  private

  # One row per (user, tracker_id): the newest point and the point count of
  # the period. Uses index_points_on_user_id_timestamp_lonlat.
  def last_reports(user_ids, since)
    sql = <<~SQL.squish
      SELECT DISTINCT ON (r.user_id, r.tracker_id)
             r.user_id, r.tracker_id, r.topic, r.timestamp,
             extract(epoch FROM r.created_at)::bigint AS received_at, r.battery, r.city, r.country_name,
             count(*) OVER (PARTITION BY r.user_id, r.tracker_id) AS points_count
      FROM (
        SELECT p.user_id,
               CASE WHEN p.source_id IS NULL THEN p.tracker_id ELSE ps.tracker_id END AS tracker_id,
               CASE WHEN p.source_id IS NULL THEN p.topic ELSE ps.topic END AS topic,
               p.timestamp, p.created_at, p.battery, p.city, p.country_name
        FROM points p
        LEFT JOIN point_sources ps ON ps.id = p.source_id
        WHERE p.user_id IN (:user_ids) AND p.import_id IS NULL AND p.timestamp >= :since
      ) r
      ORDER BY r.user_id, r.tracker_id, r.timestamp DESC, r.created_at DESC
    SQL
    rows = ActiveRecord::Base.connection.select_all(
      ActiveRecord::Base.sanitize_sql_array([sql, { user_ids:, since: }])
    ).to_a
    rows.sort_by { |row| -row['timestamp'].to_i }
  end
end
