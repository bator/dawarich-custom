# frozen_string_literal: true

# /transit/commute was merged into the /transit/stats overview (its "Commute"
# section); old links and bookmarks land there. A plain 302, so browsers do
# not cache it if the page ever comes back.
class TransitCommuteController < ApplicationController
  before_action :authenticate_user!

  def index
    days = params[:days].to_i
    redirect_to transit_stats_path(days: (days if TransitStatsController::PERIODS.include?(days)), anchor: 'commute')
  end
end
