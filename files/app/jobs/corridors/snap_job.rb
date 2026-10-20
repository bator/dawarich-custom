# frozen_string_literal: true

# Nightly (CORRIDORS_SNAP_CRON): snaps the tracks of the last days onto the
# users' frequent routes (Corridors::Snapper). No-op unless
# CORRIDORS_SNAP_ENABLED=true (and CORRIDORS_ENABLED=true).
class Corridors::SnapJob < ApplicationJob
  queue_as :low_priority

  def perform(user_id = nil, days = 3)
    return unless Corridors::Config.snap_enabled?

    users = user_id ? User.where(id: user_id) : User.where(id: TrackCorridor.select(:user_id).distinct)
    users.find_each do |user|
      results = Corridors::Snapper.new(user).call(since: days.to_i.days.ago)
      snapped = results.count { |r| r.outcome == 'snapped' }
      Rails.logger.info("[corridors] user #{user.id}: #{snapped} of #{results.size} track(s) snapped")
    rescue StandardError => e
      Rails.logger.error("[corridors] snap for user #{user.id} failed: #{e.class}: #{e.message}")
    end
  end
end
