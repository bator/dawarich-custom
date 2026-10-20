# frozen_string_literal: true

# Weekly (CORRIDORS_REBUILD_CRON): rebuilds every user's frequent routes from
# the last CORRIDORS_DAYS of real fixes (Corridors::Builder). No-op unless
# CORRIDORS_ENABLED=true.
class Corridors::RebuildJob < ApplicationJob
  queue_as :low_priority

  def perform(user_id = nil)
    return unless Corridors::Config.enabled?

    users = user_id ? User.where(id: user_id) : User.where(id: Track.select(:user_id).distinct)
    users.find_each do |user|
      routes = Corridors::Builder.new(user).call
      Rails.logger.info("[corridors] user #{user.id}: #{routes.size} frequent route(s)")
    rescue StandardError => e
      Rails.logger.error("[corridors] rebuild for user #{user.id} failed: #{e.class}: #{e.message}")
    end
  end
end
