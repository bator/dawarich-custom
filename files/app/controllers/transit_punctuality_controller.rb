# frozen_string_literal: true

# /transit/punctuality was merged into Savings, and Savings into the
# /transit/stats overview (2026-10-20); old links and bookmarks land on its
# Punctuality card. A plain 302, so browsers do not cache it.
class TransitPunctualityController < ApplicationController
  before_action :authenticate_user!

  def index
    days = params[:days].to_i
    redirect_to transit_stats_path(days: (days if TransitStatsController::PERIODS.include?(days)), anchor: 'punctuality')
  end
end
