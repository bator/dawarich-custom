# frozen_string_literal: true

# Frequent routes (docs/corridors.md). Off by default; every value can be set
# in the environment (/opt/dawarich/gtfs.env on the LXC install):
#
#   CORRIDORS_ENABLED=false          build the frequent routes weekly, map layer
#   CORRIDORS_SNAP_ENABLED=false     also snap new tracks onto them (rewrites track geometry, logged)
#   CORRIDORS_MODES=walking,cycling  track modes that get frequent routes
#   CORRIDORS_DAYS=365               history the routes are built from
#   CORRIDORS_MIN_TRIPS=5            trips a route needs
#   CORRIDORS_SNAP_BUFFER_M=30       a track snaps when CORRIDORS_SNAP_SHARE of it
#   CORRIDORS_SNAP_SHARE=0.9         lies within this distance of a route
#   CORRIDORS_FILL_GAPS=true         route the gaps of walking routes (tunnels) through
#                                    the walk snap's Atlas (GTFS_WALK_VALHALLA_URL)
#   CORRIDORS_SYNTHETIC_TRACKERS=gpx,osrm-,track-pick-,legacy-import
#                                    tracker_id prefixes of generated points (GPX
#                                    backfills, routing fills, timetable lines):
#                                    never used to build a route
module Corridors::Config
  module_function

  DEFAULT_SYNTHETIC = %w[gpx osrm- track-pick- legacy-import].freeze

  def enabled? = flag('CORRIDORS_ENABLED')

  def snap_enabled? = enabled? && flag('CORRIDORS_SNAP_ENABLED')

  def fill_gaps? = !ENV.fetch('CORRIDORS_FILL_GAPS', 'true').to_s.strip.casecmp?('false')

  def modes
    list('CORRIDORS_MODES', %w[walking cycling]) & Track.dominant_modes.keys
  end

  def days = int('CORRIDORS_DAYS', 365, 30..3650)
  def min_trips = int('CORRIDORS_MIN_TRIPS', 5, 3..100)
  def snap_buffer_m = float('CORRIDORS_SNAP_BUFFER_M', 30.0, 5.0..200.0)
  def snap_share = float('CORRIDORS_SNAP_SHARE', 0.9, 0.5..1.0)

  def synthetic_prefixes
    list('CORRIDORS_SYNTHETIC_TRACKERS', DEFAULT_SYNTHETIC)
  end

  def synthetic?(tracker_id)
    tracker_id.present? && synthetic_prefixes.any? { |prefix| tracker_id.start_with?(prefix) }
  end

  def flag(name) = ENV.fetch(name, 'false').to_s.strip.casecmp?('true')

  def list(name, default)
    value = ENV[name].to_s.split(',').map(&:strip).compact_blank
    value.empty? ? default : value
  end

  def int(name, default, range)
    value = Integer(ENV.fetch(name, ''), 10, exception: false)
    value && range.cover?(value) ? value : default
  end

  def float(name, default, range)
    value = Float(ENV.fetch(name, ''), exception: false)
    value && range.cover?(value) ? value : default
  end
end
