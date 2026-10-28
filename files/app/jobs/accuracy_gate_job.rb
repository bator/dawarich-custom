# frozen_string_literal: true

# Hides the points worse than each user's gps_accuracy_threshold (AccuracyGate),
# over the last RECENT_HOURS, or over all of a user's history with all: true.
# Not scheduled since Dawarich 1.19.0, whose own filter does this
# (gps_accuracy_filter_enabled, docs/atlas.md); kept for manual runs.
class AccuracyGateJob < ApplicationJob
  queue_as :default

  RECENT_HOURS = 48

  def perform(all = false)
    from_ts = all ? nil : RECENT_HOURS.hours.ago.to_i
    AccuracyGate.users.find_each do |user|
      result = AccuracyGate.new(user, from_ts:).call
      next if result.hidden.zero?

      Rails.logger.info("[accuracy gate] user #{user.id}: hid #{result.hidden} point(s) worse than " \
                        "#{result.threshold} m on #{result.days.size} day(s)")
    rescue StandardError => e
      Rails.logger.warn("[accuracy gate] user #{user.id}: #{e.class}: #{e.message}")
    end
  end
end
