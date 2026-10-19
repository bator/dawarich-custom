# frozen_string_literal: true

# /transit/devices was merged into /transit/coverage (one card per person with
# the devices' last reports and the coverage); old links and bookmarks land there.
# A plain 302, so browsers do not cache it if the page ever comes back.
class TransitDevicesController < ApplicationController
  before_action :authenticate_user!

  def index
    days = params[:days].to_i
    redirect_to transit_coverage_path(days: (days if TransitCoverageController::PERIODS.include?(days)))
  end
end
