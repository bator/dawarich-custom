# frozen_string_literal: true

# The Discord message of a ride. The row outlives the ride (transit_segment_id
# becomes NULL when the segment is deleted) until the message has been
# replaced by a neutral "deleted" text (tombstoned_at, review H3).
class TransitSegmentDiscordMessage < ApplicationRecord
  belongs_to :transit_segment, optional: true

  validates :channel_id, presence: true

  scope :to_tombstone, -> { where(transit_segment_id: nil, tombstoned_at: nil).where.not(message_id: nil) }
  scope :live, -> { where(tombstoned_at: nil).where.not(transit_segment_id: nil).where.not(message_id: nil) }

  def tombstone!
    update!(tombstoned_at: Time.current, hidden_at: nil, last_status: nil) if tombstoned_at.nil?
  end
end
