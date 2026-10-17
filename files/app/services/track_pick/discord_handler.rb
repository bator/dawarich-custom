# frozen_string_literal: true

# Handles the "trackpick:<date>:<user id|skip>" buttons on the existing GTFS
# Discord gateway. Hooked in by config/initializers/track_pick_discord.rb
# (prepend on Gtfs::Discord::InteractionHandler#prepare); every other click
# goes to the original handler unchanged.
class TrackPick::DiscordHandler
  MESSAGE_COMPONENT = 3
  DEFERRED_UPDATE_MESSAGE = 6
  Plan = Gtfs::Discord::InteractionHandler::Plan

  def self.track_pick?(interaction)
    interaction['type'] == MESSAGE_COMPONENT &&
      interaction.dig('data', 'custom_id').to_s.start_with?('trackpick:')
  end

  def prepare(interaction)
    # K2: never return nil for a trackpick click (no "Interaction failed")
    unless interaction['channel_id'].to_s == TrackPick::Config.channel_id.to_s &&
           interaction.dig('message', 'author', 'id').to_s == interaction['application_id'].to_s
      return Plan.new(ephemeral('Ismeretlen üzenet.'))
    end

    user = interaction.dig('member', 'user') || interaction['user'] || {}
    unless TrackPick::Config::ALLOWED_DISCORD_USER_IDS.include?(user['id'].to_s)
      return Plan.new(ephemeral(Gtfs::Discord::InteractionHandler::NOT_ALLOWED))
    end

    match = TrackPick::Config::CUSTOM_ID.match(interaction.dig('data', 'custom_id').to_s)
    return Plan.new(ephemeral('Ismeretlen gomb.')) unless match

    choice = match[2] || Array(interaction.dig('data', 'values')).first.to_s
    return Plan.new(ephemeral('Ismeretlen választás.')) unless TrackPick::Config::CHOICE.match?(choice)

    date = begin
      Date.iso8601(match[1])
    rescue ArgumentError, Date::Error # K3
      return Plan.new(ephemeral('Hibás dátum.'))
    end
    if (decided = TrackPick::Config.decision(date))
      return Plan.new(ephemeral("Erre a napra már döntöttél: #{TrackPick::Config.decided_text(decided)}"),
                      -> { remove_menu(interaction, decided) })
    end
    Plan.new({ type: DEFERRED_UPDATE_MESSAGE }, -> { work(interaction, date, choice, user) })
  end

  private

  def work(interaction, date, choice, user)
    actor = (user['global_name'].presence || user['username'].presence || 'ismeretlen').to_s
    target = TrackPick::Config.target_user
    TrackPick::Config.with_decision_lock(date) { decide(interaction, date, choice, actor, target) }
  rescue StandardError => e
    Rails.logger.error("[track_pick] #{e.class}: #{e.message}")
    { error: "Nem sikerült (#{e.class.name.demodulize}); részletek a bot logjában." } # A2: no e.message to Discord
  end

  def decide(interaction, date, choice, actor, target)
    if (decided = TrackPick::Config.decision(date)) # a parallel click won
      remove_menu(interaction, decided)
      return { error: "Erre a napra már döntöttél: #{TrackPick::Config.decided_text(decided)}" }
    end
    inserted = 0
    label = nil
    text =
      if choice == 'skip'
        label = 'Kihagyás'
        "#{date}: kihagyva (#{actor})."
      elsif choice.to_i == target.id
        label = "#{TrackPick::Config.handle(target)} (marad)"
        "#{date}: #{TrackPick::Config.handle(target)} saját trackje marad, nincs másolás (#{actor})."
      else
        source = TrackPick::Config.source_users.find { |u| u.id == choice.to_i }
        return { error: 'Ismeretlen felhasználó.' } unless source

        label = TrackPick::Config.handle(source)
        inserted = TrackPick::Copier.new(date, source, target).call
        "#{date}: #{TrackPick::Config.handle(source)} trackje átmásolva #{TrackPick::Config.handle(target)} " \
          "fiókjába – #{inserted} új pont (#{actor})."
      end
    TrackPick::Config.record_decision!(date, choice: label, user: actor, inserted:)
    Rails.logger.info("[track_pick] #{text}")
    $stdout.puts("[track_pick] #{text}")
    Gtfs::Discord::Client.new.edit_message(interaction['channel_id'], interaction.dig('message', 'id'),
                                           TrackPick::Message.done_payload(interaction.dig('message', 'embeds'), text))
    {}
  end

  def remove_menu(interaction, decided)
    text = TrackPick::Message.decided_line(decided)
    Gtfs::Discord::Client.new.edit_message(interaction['channel_id'], interaction.dig('message', 'id'),
                                           { content: text, components: [] })
    {}
  rescue StandardError => e
    Rails.logger.error("[track_pick] remove menu failed: #{e.class}: #{e.message}")
    {}
  end

  def ephemeral(text)
    { type: 4, data: { content: text, flags: 64 } }
  end
end
