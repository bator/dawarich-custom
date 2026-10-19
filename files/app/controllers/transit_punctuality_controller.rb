# frozen_string_literal: true

# /transit/punctuality was merged into /transit/savings (a Punctuality section
# below the cost chart); old links and bookmarks land on that section.
# A plain 302, so browsers do not cache it if the page ever comes back.
class TransitPunctualityController < ApplicationController
  before_action :authenticate_user!

  def index
    days = params[:days].to_i
    redirect_to transit_savings_path(days: (days if TransitSavingsController::PERIODS.include?(days)), anchor: 'punctuality')
  end
end
