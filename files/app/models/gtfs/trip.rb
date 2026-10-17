# frozen_string_literal: true

class Gtfs::Trip < ApplicationRecord
  include Gtfs::Versioned

  scope :usable, -> { where(times_valid: true) }
end
