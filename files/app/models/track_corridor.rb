# frozen_string_literal: true

# A frequent route of a user: the median line of the trips of one cluster
# (Corridors::Builder). Rebuilt weekly as a whole per user.
class TrackCorridor < ApplicationRecord
  belongs_to :user
end
