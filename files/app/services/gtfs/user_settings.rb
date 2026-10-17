# frozen_string_literal: true

# GTFS-related user settings, stored in users.settings (spec 6):
#   gtfs_enabled         opt-in for matching (default false)
#   gtfs_feed_keys       optional list of feed keys to match against (default: all enabled feeds)
#   gtfs_min_confidence  display/API threshold (default GTFS_MATCH_MIN_CONFIDENCE, never below DROP_BELOW)
# Edited on Settings → Public transit (Phase 3) or from the console.
class Gtfs::UserSettings
  def self.opted_in_users
    User.where("users.settings->>'gtfs_enabled' = 'true'")
  end

  def initialize(user)
    @settings = user.settings || {}
  end

  def enabled?
    ActiveModel::Type::Boolean.new.cast(@settings['gtfs_enabled']) == true
  end

  def feed_keys
    Array(@settings['gtfs_feed_keys']).map(&:to_s).compact_blank.presence
  end

  def min_confidence
    value = @settings['gtfs_min_confidence'].presence&.to_f || Gtfs::Config::MIN_CONFIDENCE
    value.clamp(Gtfs::Config::DROP_BELOW, 1.0)
  end
end
