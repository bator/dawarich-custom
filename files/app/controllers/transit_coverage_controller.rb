# frozen_string_literal: true

# /transit/coverage: per user a "typical day" (share of days with points
# per hour) and a per-day coverage tracker, plus the longest silent gaps (Gtfs::CoverageReport). Admins see every user,
# everyone else only themselves. Like /transit/devices the shell renders at
# once and the report comes in a lazy Turbo Frame, cached for CACHE_TTL.
class TransitCoverageController < ApplicationController
  PERIODS = [30, 90].freeze
  DEFAULT_DAYS = 30
  FRAME = 'transit-coverage'
  CACHE_TTL = 10.minutes

  before_action :authenticate_user!

  def index
    @days = PERIODS.include?(params[:days].to_i) ? params[:days].to_i : DEFAULT_DAYS
    @zone = ActiveSupport::TimeZone[current_user.timezone_iana] || Time.zone
    return unless turbo_frame_request?

    @users = current_user.admin? ? User.order(:id).to_a : [current_user]
    @report_meta = Gtfs::CoverageReport.new([], since: @days.days.ago.beginning_of_day, zone: @zone)
    @cached_at, @reports = Rails.cache.fetch(['transit-coverage/v3', @users.map(&:id), @days, @zone.name], expires_in: CACHE_TTL) do
      [Time.current, Gtfs::CoverageReport.new(@users.map(&:id), since: @days.days.ago.beginning_of_day, zone: @zone).call]
    end
    render partial: 'report'
  end
end
