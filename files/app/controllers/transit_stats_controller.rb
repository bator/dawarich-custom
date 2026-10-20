# frozen_string_literal: true

# /transit/stats, the overview (the former Savings page is part of it since
# 2026-10-20): totals compared with the period before (same length), the
# rides drawn as a network (Gtfs::NetworkMap), punctuality (Gtfs::PunctualityStats),
# the CO2 and cost estimate against the car (Gtfs::SavingsEstimate), the
# recurring trips paired with their way back (Gtfs::CommuteStats), and the
# rides by mode, operator and line (Gtfs::PeriodStats). Same rides as the
# /transit list (Gtfs::SegmentQuery), counting only confirmed and auto-accepted ones.
class TransitStatsController < ApplicationController
  PERIODS = TransitSegmentsController::PERIODS
  DEFAULT_DAYS = 90

  before_action :authenticate_user!

  def index
    @enabled = Gtfs::UserSettings.new(current_user).enabled?
    @days = PERIODS.include?(params[:days].to_i) ? params[:days].to_i : DEFAULT_DAYS
    @zone = ActiveSupport::TimeZone[current_user.timezone_iana] || Time.zone
    @since = @days.days.ago
    segments = Gtfs::SegmentQuery.new(current_user, start_at: @since.to_i).scope.to_a
    @stats = Gtfs::PeriodStats.new(segments, zone: @zone)
    before = Gtfs::SegmentQuery.new(current_user, start_at: (@since - @days.days).to_i, end_at: @since.to_i - 1).scope.to_a
    @previous = Gtfs::PeriodStats.new(before, zone: @zone)
    @savings = Gtfs::SavingsEstimate.new(@stats.rides, days: @days, since: @since, zone: @zone)
    @punctuality = Gtfs::PunctualityStats.new(@stats.rides, zone: @zone)
    @commute = Gtfs::CommuteStats.new(@stats.rides, zone: @zone)
    @colors = Api::TransitSegmentSerializer.colors_for(@stats.rides)
    @network = Gtfs::NetworkMap.new(@stats.rides, user: current_user)
  end
end
