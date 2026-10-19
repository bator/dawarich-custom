# frozen_string_literal: true

# /transit/punctuality: measured delays per line (Gtfs::PunctualityStats).
class TransitPunctualityController < ApplicationController
  include TransitPeriodRides

  PERIODS = TransitPeriodRides::ANALYSIS_PERIODS

  before_action :authenticate_user!

  def index
    load_period_rides
    @punctuality = Gtfs::PunctualityStats.new(@period_stats.rides, zone: @zone)
    @colors = Api::TransitSegmentSerializer.colors_for(@punctuality.lines.map(&:segment))
  end
end
