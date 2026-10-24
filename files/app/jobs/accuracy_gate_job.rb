# frozen_string_literal: true

# Hides the points worse than each user's gps_accuracy_threshold (AccuracyGate):
# hourly over the last RECENT_HOURS (config/schedule.yml, ACCURACY_GATE_CRON),
# and over all of a user's history with all: true (ACCURACY_GATE_NIGHTLY_CRON),
# which also catches what Points::AnomalyBackfillUserJob showed again.
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
