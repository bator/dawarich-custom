# frozen_string_literal: true

# Used by the transit analysis pages (savings with punctuality): the
# period filter and the counted rides of the period, i.e. the same rows the
# /transit list shows (Gtfs::SegmentQuery) minus the uncertain ones
# (Gtfs::PeriodStats).
module TransitPeriodRides
  extend ActiveSupport::Concern

  ANALYSIS_PERIODS = [30, 90, 365].freeze
  ANALYSIS_DEFAULT_DAYS = 90

  private

  def load_period_rides(periods: ANALYSIS_PERIODS, default: ANALYSIS_DEFAULT_DAYS)
    @enabled = Gtfs::UserSettings.new(current_user).enabled?
    @days = periods.include?(params[:days].to_i) ? params[:days].to_i : default
    @zone = ActiveSupport::TimeZone[current_user.timezone_iana] || Time.zone
    @since = @days.days.ago
    segments = Gtfs::SegmentQuery.new(current_user, start_at: @since.to_i).scope.to_a
    @period_stats = Gtfs::PeriodStats.new(segments, zone: @zone)
  end
end
