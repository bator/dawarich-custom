# frozen_string_literal: true

class TransitSegmentPoint < ApplicationRecord
  belongs_to :transit_segment
  belongs_to :point
end
