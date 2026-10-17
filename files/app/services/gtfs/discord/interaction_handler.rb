# frozen_string_literal: true

# Handles a click on a ride's button or a choice in its "Másik járat" select
# menu (INTERACTION_CREATE from the gateway) in two steps (review H7):
#
# 1. #prepare checks the click and returns a Plan: the answer to send to
#    Discord at once (within its 3 s) and, for a review, the work to do
#    after that answer. Answers:
#    - nil (no answer at all) for a message this instance did not post or a
#      channel other than DISCORD_TRANSIT_CHANNEL_ID: another instance with
#      the same bot token (dev/prod) may own it (review H2);
#    - type 4 with the ephemeral flag: a note only the clicker sees (not on
#      the allow-list, unknown button);
#    - type 7 (UPDATE_MESSAGE) for a ride that was deleted (tombstone);
#    - type 6 (DEFERRED_UPDATE_MESSAGE) for a review.
# 2. The work runs Gtfs::SegmentReview (the same code path as the web
#    action) and returns { segment_id: } (the gateway then edits the message
#    once, with a fresh map image) or { error: } (sent as an ephemeral
#    follow-up).
#
# Only the Discord users in DISCORD_TRANSIT_ALLOWED_DISCORD_USER_IDS may
# act; the list is required (review H1, Gtfs::Discord::Config#enabled?).
class Gtfs::Discord::InteractionHandler
  MESSAGE_COMPONENT = 3
  DEFERRED_UPDATE_MESSAGE = 6
  UPDATE_MESSAGE = 7
  CHANNEL_MESSAGE = 4
  EPHEMERAL = 64
  NOT_ALLOWED = 'Ehhez a gombhoz nincs jogosultságod.'
  GONE_ERROR = 'Ez a menet már nem elérhető.'

  Plan = Struct.new(:response, :work)

  # Answer and work in one go (specs, simple callers). Returns the answer,
  # or the ephemeral error if the work failed.
  def call(interaction)
    plan = prepare(interaction)
    return nil unless plan

    outcome = plan.work&.call || {}
    outcome[:error] ? ephemeral(outcome[:error]) : plan.response
  end

  def prepare(interaction)
    return nil unless interaction['type'] == MESSAGE_COMPONENT
    return nil unless interaction['channel_id'].to_s == Gtfs::Discord::Config.channel_id.to_s

    record = TransitSegmentDiscordMessage.find_by(channel_id: interaction['channel_id'].to_s,
                                                  message_id: interaction.dig('message', 'id').to_s)
    return nil unless record

    user = interaction.dig('member', 'user') || interaction['user'] || {}
    return Plan.new(ephemeral(NOT_ALLOWED)) unless allowed?(user['id'])

    plan_for(record, interaction, user)
  end

  def ephemeral(text)
    { type: CHANNEL_MESSAGE, data: { content: text, flags: EPHEMERAL } }
  end

  private

  def plan_for(record, interaction, user)
    match = Gtfs::Discord::MessageBuilder::CUSTOM_ID.match(interaction.dig('data', 'custom_id').to_s)
    return Plan.new(ephemeral('Ismeretlen gomb.')) unless match

    segment = record.transit_segment
    if segment.nil?
      record.tombstone!
      return Plan.new(update(Gtfs::Discord::MessageBuilder.deleted_payload))
    end
    return Plan.new(ephemeral('Ismeretlen gomb.')) unless segment.id == match[2].to_i

    values = interaction.dig('data', 'values')
    Plan.new({ type: DEFERRED_UPDATE_MESSAGE }, -> { review(record, segment, match[1], actor_name(user), values) })
  end

  def review(record, segment, action, actor, values)
    Gtfs::SegmentReview.new(segment.user, source: 'discord').call(segment.id, action, **choice(action, values))
    segment.reload
    record.update!(last_status: segment.status, reviewed_by: segment.reviewed? ? actor : nil)
    Rails.logger.info("[GTFS discord] segment #{segment.id}: #{action} by #{actor}" \
                      "#{" -> #{segment.route_short_name} (trip #{segment.trip_gtfs_id})" if action == 'choose'}")
    { segment_id: segment.id }
  rescue Gtfs::SegmentReview::NotFound
    { error: GONE_ERROR, segment_id: segment.id }
  rescue Gtfs::SegmentReview::Invalid => e
    { error: "Nem sikerült: #{e.message}" }
  end

  # The select menu sends the chosen option's value: "<feed id>:<trip id>".
  def choice(action, values)
    return {} unless action == 'choose'

    feed_id, trip_gtfs_id = Gtfs::Discord::MessageBuilder.parse_choice(Array(values).first)
    raise Gtfs::SegmentReview::Invalid, 'no trip chosen' unless trip_gtfs_id

    { feed_id:, trip_gtfs_id: }
  end

  def allowed?(discord_user_id)
    Gtfs::Discord::Config.allowed_discord_user_ids.include?(discord_user_id.to_s)
  end

  def actor_name(user)
    (user['global_name'].presence || user['username'].presence || 'ismeretlen').to_s.truncate(64)
  end

  def update(data)
    { type: UPDATE_MESSAGE, data: }
  end
end
