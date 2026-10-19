# frozen_string_literal: true

# /transit/coverage: one card per user with the last live report of each
# device (Gtfs::DeviceReports), a "typical day" (share of days with points
# per hour), a per-day coverage tracker and the longest silent gaps
# (Gtfs::CoverageReport). Admins see every user, everyone else only
# themselves. The shell renders at once and the cards come in a lazy Turbo
# Frame; devices are cached for DEVICES_TTL, the coverage for CACHE_TTL.
class TransitCoverageController < ApplicationController
  PERIODS = [7, 30, 90].freeze
  DEFAULT_DAYS = 30
  FRAME = 'transit-coverage'
  CACHE_TTL = 10.minutes
  DEVICES_TTL = 2.minutes
  # Status dot of the last report: green up to FRESH, yellow up to STALE.
  FRESH = 15.minutes
  STALE = 24.hours

  before_action :authenticate_user!

  def index
    @days = PERIODS.include?(params[:days].to_i) ? params[:days].to_i : DEFAULT_DAYS
    @zone = ActiveSupport::TimeZone[current_user.timezone_iana] || Time.zone
    return unless turbo_frame_request?

    @users = current_user.admin? ? User.order(:id).to_a : [current_user]
    user_ids = @users.map(&:id)
    since = @days.days.ago.beginning_of_day
    @report_meta = Gtfs::CoverageReport.new([], since:, zone: @zone)
    @cached_at, @reports = Rails.cache.fetch(['transit-coverage/v4', user_ids, @days, @zone.name], expires_in: CACHE_TTL) do
      [Time.current, Gtfs::CoverageReport.new(user_ids, since:, zone: @zone).call]
    end
    @devices_at, rows = Rails.cache.fetch(['transit-devices/v3', user_ids, @days], expires_in: DEVICES_TTL) do
      [Time.current, Gtfs::DeviceReports.new(user_ids, since:).call]
    end
    @devices = rows.group_by { |row| row['user_id'] }
    render partial: 'report'
  end
end
