# frozen_string_literal: true

# Keeps the Discord channel in line with what users may see (review H3):
# - a message whose ride was deleted (rematch, deleted points, privacy zone,
#   deleted user) is edited to "🗑️ Ez a menet törölve lett." without line,
#   stops, times, map image or buttons, then marked tombstoned;
# - a message whose ride is now hidden (a privacy zone added later, matching
#   turned off) is replaced by a neutral text; when the ride is visible again
#   the full message comes back.
# Runs after every matched day of a user (user_id) and daily for everyone
# (Gtfs::MatchRecentJob). Never touches points.
class Gtfs::Discord::MessageCleanupJob < ApplicationJob
  queue_as :default

  retry_on Gtfs::Discord::Client::RateLimited, wait: 30.seconds, attempts: 5

  def perform(user_id = nil)
    return unless Gtfs::Discord::Config.enabled?

    client = Gtfs::Discord::Client.new
    TransitSegmentDiscordMessage.to_tombstone.find_each { |record| tombstone(record, client) }
    live = TransitSegmentDiscordMessage.live.joins(:transit_segment)
    live = live.where(transit_segments: { user_id: }) if user_id
    live.includes(transit_segment: :user).group_by { |record| record.transit_segment.user }.each do |user, records|
      visible = TransitSegment.reviewable_for(user).where(id: records.map(&:transit_segment_id)).pluck(:id).to_set
      records.each { |record| sync_visibility(record, visible.include?(record.transit_segment_id), client) }
    end
  end

  private

  def tombstone(record, client)
    client.edit_message(record.channel_id, record.message_id, Gtfs::Discord::MessageBuilder.deleted_payload)
    record.tombstone!
  rescue Gtfs::Discord::Client::Error => e
    raise unless e.status == 404 # the message itself was deleted on Discord

    record.tombstone!
  end

  def sync_visibility(record, visible, client)
    if !visible
      Gtfs::Discord::SyncMessageJob.hide!(record, client:)
    elsif record.hidden_at
      Gtfs::Discord::SyncMessageJob.perform_now(record.transit_segment_id)
    end
  rescue Gtfs::Discord::Client::Error => e
    Rails.logger.warn("[GTFS discord] message of segment #{record.transit_segment_id}: #{e.message}")
  end
end
