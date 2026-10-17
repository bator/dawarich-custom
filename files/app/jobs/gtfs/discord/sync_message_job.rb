# frozen_string_literal: true

# Brings a ride's Discord message up to date after it was confirmed, rejected
# or switched on the web, through the API or on Discord (also
# `gtfs:discord_refresh`). A confirmed or rejected ride collapses to one line
# without the map image; otherwise the map is rendered again and replaces the
# old attachment. A ride the user can no longer see (privacy zone added,
# points deleted, matching turned off) gets a neutral text without image or
# buttons instead (review H3).
class Gtfs::Discord::SyncMessageJob < ApplicationJob
  queue_as :default

  retry_on Gtfs::Discord::Client::RateLimited, wait: 30.seconds, attempts: 5
  retry_on Gtfs::Discord::Client::Error, wait: 1.minute, attempts: 3

  def perform(segment_id)
    return unless Gtfs::Discord::Config.enabled?

    record = TransitSegmentDiscordMessage.includes(transit_segment: :user).find_by(transit_segment_id: segment_id)
    return if record.nil? || record.message_id.blank? || record.tombstoned_at

    segment = record.transit_segment
    return self.class.hide!(record) unless TransitSegment.reviewable_for(segment.user).exists?(id: segment.id)

    actor = actor_for(record, segment)
    # A decided ride collapses to one line without the map; undo (auto again)
    # uploads a fresh map image.
    image = Gtfs::Discord::RideImage.call(segment) unless Gtfs::Discord::MessageBuilder.compact?(segment)
    payload = Gtfs::Discord::MessageBuilder.new(segment, actor:, image: image&.filename).payload
    payload[:attachments] = [] unless image # drop an old image
    Gtfs::Discord::Client.new.edit_message(record.channel_id, record.message_id, payload, files: [image].compact)
    record.update!(last_status: segment.status, reviewed_by: actor, hidden_at: nil)
  end

  def self.hide!(record, client: Gtfs::Discord::Client.new)
    return if record.hidden_at

    client.edit_message(record.channel_id, record.message_id, Gtfs::Discord::MessageBuilder.hidden_payload)
    record.update!(hidden_at: Time.current)
  end

  private

  # Status unchanged since the last edit (e.g. a refresh): keep who clicked
  # on Discord; a change made in Dawarich is shown as "Dawarich".
  def actor_for(record, segment)
    return nil unless segment.reviewed?
    return record.reviewed_by if record.last_status == segment.status && record.reviewed_by.present?

    'Dawarich'
  end
end
