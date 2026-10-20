# frozen_string_literal: true

# /transit/savings was merged into the /transit/stats overview on 2026-10-20
# (its CO2 and cost card, anchor #impact); old links and bookmarks land there.
# A plain 302, so browsers do not cache it if the page ever comes back.
class TransitSavingsController < ApplicationController
  before_action :authenticate_user!

  def index
    days = params[:days].to_i
    redirect_to transit_stats_path(days: (days if TransitStatsController::PERIODS.include?(days)), anchor: 'impact')
  end
end
