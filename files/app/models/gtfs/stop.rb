# frozen_string_literal: true

class Gtfs::Stop < ApplicationRecord
  include Gtfs::Versioned

  # GTFS location_type values
  LOCATION_TYPES = { stop: 0, station: 1, entrance: 2, generic_node: 3, boarding_area: 4 }.freeze
end
