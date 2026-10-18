# frozen_string_literal: true

# /transit/stats: totals of the current user's rides over the /transit
# periods (Gtfs::PeriodStats). Same rides as the /transit list
# (Gtfs::SegmentQuery), counting only confirmed and auto-accepted ones.
class TransitStatsController < ApplicationController
  PERIODS = TransitSegmentsController::PERIODS
  # Up to this many days the bar row is per week, above it per month.
  WEEKLY_UP_TO = 90

  before_action :authenticate_user!

  def index
    @enabled = Gtfs::UserSettings.new(current_user).enabled?
    @days = PERIODS.include?(params[:days].to_i) ? params[:days].to_i : 30
    @zone = ActiveSupport::TimeZone[current_user.timezone_iana] || Time.zone
    @since = @days.days.ago
    segments = Gtfs::SegmentQuery.new(current_user, start_at: @since.to_i).scope.to_a
    @stats = Gtfs::PeriodStats.new(segments, zone: @zone)
    @colors = Api::TransitSegmentSerializer.colors_for(@stats.top_lines.map { |row| row[:segment] })
    @bucket = @days <= WEEKLY_UP_TO ? :week : :month
    @histogram = @stats.histogram(from: @zone.at(@since.to_i).to_date, by: @bucket)
  end
end
