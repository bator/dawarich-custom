# frozen_string_literal: true

class Gtfs::Route < ApplicationRecord
  include Gtfs::Versioned

  # Basic GTFS route_type values. Extended types (100-1700) are stored as-is.
  BASIC_TYPES = {
    0 => 'tram', 1 => 'subway', 2 => 'rail', 3 => 'bus', 4 => 'ferry',
    5 => 'cable_tram', 6 => 'aerial_lift', 7 => 'funicular', 11 => 'trolleybus', 12 => 'monorail'
  }.freeze

  def display_name
    short_name.presence || long_name
  end
end
