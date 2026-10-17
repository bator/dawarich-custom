# frozen_string_literal: true

# Posts a message with Jóváhagyom / Elutasítom buttons for each new `auto`
# ride of a user (enqueued after a day was matched): the users in
# DISCORD_TRANSIT_USER_IDS, or with "all" every user. Only rides that are
# visible to the user (privacy zones, threshold) and started within
# DISCORD_TRANSIT_MAX_AGE_HOURS; at most DISCORD_TRANSIT_MAX_PER_RUN per run.
class Gtfs::Discord::NotifyJob < ApplicationJob
  queue_as :default

  retry_on Gtfs::Discord::Client::RateLimited, wait: 30.seconds, attempts: 5
  retry_on Gtfs::Discord::Client::Error, wait: 1.minute, attempts: 3

  def perform(user_id)
    return unless Gtfs::Discord::Config.enabled?

    user = User.find_by(id: user_id)
    return unless user && Gtfs::Discord::Config.posts_for?(user)

    pending(user).each { |segment| self.class.post(segment) }
  end

  # Posts one ride (also used by `gtfs:discord_post`). Returns the message
  # row, or nil if the ride already has a message.
  def self.post(segment, client: Gtfs::Discord::Client.new, channel_id: Gtfs::Discord::Config.channel_id)
    record = TransitSegmentDiscordMessage.create!(transit_segment: segment, channel_id:) # claim
    image = Gtfs::Discord::RideImage.call(segment) unless Gtfs::Discord::MessageBuilder.compact?(segment)
    payload = Gtfs::Discord::MessageBuilder.new(segment, image: image&.filename).payload
    response = client.post_message(channel_id, payload, files: [image].compact)
    record.update!(message_id: response.fetch('id'), last_status: segment.status)
    record
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue StandardError
    record&.destroy
    raise
  end

  private

  def pending(user)
    TransitSegment.visible_for(user).auto
                  .where(started_at: Gtfs::Discord::Config.max_age.ago.to_i..)
                  .where.missing(:discord_message)
                  .order(:started_at)
                  .limit(Gtfs::Discord::Config.max_per_run)
  end
end
