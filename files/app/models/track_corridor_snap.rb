# frozen_string_literal: true

# A track snapped onto a frequent route, with its geometry from before the
# snap (Corridors::Snapper, `corridors:revert`).
class TrackCorridorSnap < ApplicationRecord
  belongs_to :track
  belongs_to :user
end
