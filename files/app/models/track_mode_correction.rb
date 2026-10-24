# frozen_string_literal: true

# A transport mode a user set by hand on a track segment (TrackModeCorrections).
class TrackModeCorrection < ApplicationRecord
  belongs_to :user

  validates :start_at, :end_at, :transportation_mode, :captured_at, presence: true
end
