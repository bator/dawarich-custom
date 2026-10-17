# frozen_string_literal: true

# Spec 12.1: opt-in, feed selection, display threshold, timetable status,
# attribution and "rematch the whole history".
class Settings::TransitController < ApplicationController
  MIN_CONFIDENCE_RANGE = 0.5..0.95

  before_action :authenticate_user!

  rate_limit to: 2, within: 1.hour, only: :rematch_all, by: -> { "transit-rematch-all:#{current_user.id}" },
             with: -> { redirect_to settings_transit_path, alert: t('settings.transit_controller.rate_limited') }

  def show
    @settings = Gtfs::UserSettings.new(current_user)
    @feeds = Gtfs::Feed.enabled.order(:name)
    @state = Gtfs::UserState.find_by(user_id: current_user.id)
  end

  def update
    was_enabled = Gtfs::UserSettings.new(current_user).enabled?
    current_user.update!(settings: (current_user.settings || {}).merge(coerced_params))
    start_first_backfill if !was_enabled && Gtfs::UserSettings.new(current_user).enabled?

    redirect_to settings_transit_path, notice: t('settings.transit_controller.saved')
  end

  def rematch_all
    unless Gtfs::UserSettings.new(current_user).enabled?
      return redirect_to settings_transit_path, alert: t('settings.transit_controller.disabled')
    end

    Gtfs::Backfill.start!(current_user, restart: true)
    redirect_to settings_transit_path, notice: t('settings.transit_controller.rematch_started')
  end

  private

  def settings_params
    params.fetch(:transit, {}).permit(:enabled, :min_confidence, feed_keys: [])
  end

  def coerced_params
    raw = settings_params
    allowed_keys = Gtfs::Feed.enabled.pluck(:key)
    keys = Array(raw[:feed_keys]).map(&:to_s) & allowed_keys
    confidence = raw[:min_confidence].presence&.to_f || Gtfs::Config::MIN_CONFIDENCE
    {
      'gtfs_enabled' => ActiveModel::Type::Boolean.new.cast(raw[:enabled]) == true,
      'gtfs_feed_keys' => keys.presence,
      'gtfs_min_confidence' => confidence.clamp(MIN_CONFIDENCE_RANGE.begin, MIN_CONFIDENCE_RANGE.end).round(2)
    }
  end

  # Spec 10: the first opt-in matches the history the timetables still cover.
  def start_first_backfill
    return unless Gtfs.enabled? && Gtfs::Backfill.status(current_user).empty?

    Gtfs::Backfill.start!(current_user)
  end
end
