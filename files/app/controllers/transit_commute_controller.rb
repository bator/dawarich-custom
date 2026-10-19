# frozen_string_literal: true

# /transit/commute: the user's recurring trips (Gtfs::CommuteStats).
class TransitCommuteController < ApplicationController
  include TransitPeriodRides

  PERIODS = TransitPeriodRides::ANALYSIS_PERIODS

  before_action :authenticate_user!

  def index
    load_period_rides
    @commute = Gtfs::CommuteStats.new(@period_stats.rides, zone: @zone)
    @colors = Api::TransitSegmentSerializer.colors_for(@commute.trips.flat_map { |trip| trip.lines.map(&:first) })
  end
end
