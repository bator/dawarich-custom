# frozen_string_literal: true

# /transit/savings: CO2 and cost estimate of the rides vs the car
# (Gtfs::SavingsEstimate) and, in the same period, the measured delays per
# line (Gtfs::PunctualityStats; the former /transit/punctuality).
class TransitSavingsController < ApplicationController
  include TransitPeriodRides

  PERIODS = TransitPeriodRides::ANALYSIS_PERIODS

  before_action :authenticate_user!

  def index
    load_period_rides
    @savings = Gtfs::SavingsEstimate.new(@period_stats.rides, days: @days, since: @since, zone: @zone)
    @punctuality = Gtfs::PunctualityStats.new(@period_stats.rides, zone: @zone)
    @colors = Api::TransitSegmentSerializer.colors_for(@punctuality.lines.map(&:segment))
  end
end
