# frozen_string_literal: true

# /transit/devices: when each person's devices last reported a live point.
# A device is a tracker_id (OwnTracks tid, the device_id of the Dawarich app,
# Overland or Traccar), resolved the way Points::SlimCollectionQuery does it:
# from point_sources when the point has a source_id, else from the legacy
# column. Imported points are left out, they are history, not reports.
# Admins see every user, everyone else only their own devices.
#
# Speed: points have no index on the device, so the query reads every live
# point of the period (about 0.3 s for 7 days, 1.6 s for 30, 5 s for 90 on
# CT 139). The page shell renders at once and the list comes in a lazy Turbo
# Frame; the result is cached for CACHE_TTL per (users, period).
class TransitDevicesController < ApplicationController
  PERIODS = [1, 7, 30, 90].freeze
  DEFAULT_DAYS = 7
  FRAME = 'transit-devices'
  CACHE_TTL = 2.minutes
  # Status dot of the last report: green up to FRESH, yellow up to STALE.
  FRESH = 15.minutes
  STALE = 24.hours

  before_action :authenticate_user!

  def index
    @days = PERIODS.include?(params[:days].to_i) ? params[:days].to_i : DEFAULT_DAYS
    @zone = ActiveSupport::TimeZone[current_user.timezone_iana] || Time.zone
    return unless turbo_frame_request?

    users = current_user.admin? ? User.all.to_a : [current_user]
    @cached_at, rows = cached_reports(users.map(&:id).sort)
    devices = rows.group_by { |row| row['user_id'] }
    people = users.map { |user| [user, devices.fetch(user.id, [])] }
    @silent, @people = people.partition { |_, list| list.empty? }
    @people.sort_by! { |user, list| [-list.first['timestamp'].to_i, user.display_name.downcase] }
    render partial: 'list'
  end

  private

  # [computed_at, rows]
  def cached_reports(user_ids)
    Rails.cache.fetch(['transit-devices/v2', user_ids, @days], expires_in: CACHE_TTL) do
      [Time.current, last_reports(user_ids, @days.days.ago.to_i)]
    end
  end

  # One row per (user, tracker_id): point count and newest timestamp from a
  # GROUP BY, then the newest point itself from a LATERAL lookup at that
  # (user_id, timestamp) on index_points_on_user_id_timestamp_lonlat, instead
  # of sorting every live point of the period (DISTINCT ON + window count).
  def last_reports(user_ids, since)
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
      ActiveRecord::Base.sanitize_sql_array([sql, { user_ids:, since: }])
    ).to_a
    rows.sort_by { |row| -row['timestamp'].to_i }
  end
end
