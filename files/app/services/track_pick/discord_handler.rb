# frozen_string_literal: true

# Handles the "trackpick:<date>:..." controls on the existing GTFS Discord
# gateway. Hooked in by config/initializers/track_pick_discord.rb (prepend on
# Gtfs::Discord::InteractionHandler#prepare); every other click goes to the
# original handler unchanged.
#
# - whole-day / inner-city select: UPDATE_MESSAGE with the re-stated controls, no copy;
# - Confirm: copy (whole day from one user, optionally the inner city from another), then
#   the message collapses to one line;
# - Skip: nothing is copied, the message collapses.
# Older messages (one select, or one button per user) still work: the pick is the whole day.
class TrackPick::DiscordHandler
  MESSAGE_COMPONENT = 3
  DEFERRED_UPDATE_MESSAGE = 6
  UPDATE_MESSAGE = 7
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

    date = begin
      Date.iso8601(match[1])
    rescue ArgumentError, Date::Error # K3
      return Plan.new(ephemeral('Hibás dátum.'))
    end
    if (decided = TrackPick::Config.decision(date))
      return Plan.new(ephemeral("Erre a napra már döntöttél: #{TrackPick::Config.decided_text(decided)}"),
                      -> { remove_menu(interaction, decided) })
    end

    action = parse(match[2], Array(interaction.dig('data', 'values')).first.to_s)
    return Plan.new(ephemeral('Ismeretlen választás.')) unless action

    case action[:kind]
    when :select
      rows, line = TrackPick::Message.restate(Array(interaction.dig('message', 'components')),
                                              date:, day: action[:day], bp: action[:bp])
      Plan.new({ type: UPDATE_MESSAGE, data: { content: line, components: rows } })
    when :confirm
      return Plan.new(ephemeral('Előbb válaszd ki az egész napot.')) unless action[:day]

      Plan.new({ type: DEFERRED_UPDATE_MESSAGE }, -> { work(interaction, date, action[:day], action[:bp], user) })
    when :skip
      Plan.new({ type: DEFERRED_UPDATE_MESSAGE }, -> { work(interaction, date, 'skip', 'same', user) })
    end
  end

  private

  # rest: the custom_id after the date; value: the picked select value
  def parse(rest, value)
    pick = TrackPick::Config::PICK
    bp_pick = TrackPick::Config::BP_PICK
    case rest
    when nil # older single select: value = user id | skip
      return nil unless TrackPick::Config::CHOICE.match?(value)

      value == 'skip' ? { kind: :skip } : { kind: :confirm, day: value, bp: 'same' }
    when 'skip' then { kind: :skip }
    when /\A\d+\z/ then { kind: :confirm, day: rest, bp: 'same' } # older per-user button
    when /\Ad:(.+)\z/
      bp = Regexp.last_match(1)
      return nil unless bp_pick.match?(bp) && value.match?(/\A\d+\z/)

      { kind: :select, day: value, bp: }
    when /\Ab:(.+)\z/
      day = Regexp.last_match(1)
      return nil unless pick.match?(day) && bp_pick.match?(value)

      { kind: :select, day: (day == '-' ? nil : day), bp: value }
    when /\Aok:([^:]+):(.+)\z/
      day = Regexp.last_match(1)
      bp = Regexp.last_match(2)
      return nil unless pick.match?(day) && bp_pick.match?(bp)

      { kind: :confirm, day: (day == '-' ? nil : day), bp: }
    end
  end

  def work(interaction, date, day, bp, user)
    actor = (user['global_name'].presence || user['username'].presence || 'ismeretlen').to_s
    target = TrackPick::Config.target_user
    TrackPick::Config.with_decision_lock(date) { decide(interaction, date, day, bp, actor, target) }
  rescue StandardError => e
    Rails.logger.error("[track_pick] #{e.class}: #{e.message}")
    { error: "Nem sikerült (#{e.class.name.demodulize}); részletek a bot logjában." } # A2: no e.message to Discord
  end

  def decide(interaction, date, day, bp, actor, target)
    if (decided = TrackPick::Config.decision(date)) # a parallel click won
      remove_menu(interaction, decided)
      return { error: "Erre a napra már döntöttél: #{TrackPick::Config.decided_text(decided)}" }
    end

    inserted = 0
    if day == 'skip'
      label = 'Kihagyás'
      text = "#{date}: kihagyva (#{actor})."
    else
      users = TrackPick::Config.source_users.index_by { |u| u.id.to_s }
      day_user = users[day] or return { error: 'Ismeretlen felhasználó.' }
      bp_user = bp == 'same' || bp == day ? nil : (users[bp] or return { error: 'Ismeretlen felhasználó.' })
      inserted = copy(date, day_user, bp_user, target)
      label = pick_label(day_user, bp_user, target)
      text = "#{date}: #{label} → #{TrackPick::Config.handle(target)}, " \
             "#{inserted.positive? ? "#{inserted} új pont" : 'nincs másolás'} (#{actor})."
    end
    TrackPick::Config.record_decision!(date, choice: label, user: actor, inserted:)
    Rails.logger.info("[track_pick] #{text}")
    $stdout.puts("[track_pick] #{text}")
    Gtfs::Discord::Client.new.edit_message(interaction['channel_id'], interaction.dig('message', 'id'),
                                           TrackPick::Message.done_payload(text))
    {}
  end

  # whole day from day_user; with bp_user the inner city comes from bp_user instead.
  # The target's own points always stay (INSERT only).
  # (Copier returns 0 when the source is the target.)
  def copy(date, day_user, bp_user, target)
    return TrackPick::Copier.new(date, day_user, target).call unless bp_user

    ActiveRecord::Base.transaction do
      TrackPick::Copier.new(date, day_user, target, scope: :outside).call +
        TrackPick::Copier.new(date, bp_user, target, scope: :inside).call
    end
  end

  def pick_label(day_user, bp_user, target)
    day = "#{TrackPick::Config.handle(day_user)}#{day_user.id == target.id ? ' (marad)' : ''}"
    return day unless bp_user

    "#{day} (egész nap) + #{TrackPick::Config.handle(bp_user)} (belváros)"
  end

  def remove_menu(interaction, decided)
    Gtfs::Discord::Client.new.edit_message(interaction['channel_id'], interaction.dig('message', 'id'),
                                           TrackPick::Message.done_payload(TrackPick::Message.decided_line(decided)))
    {}
  rescue StandardError => e
    Rails.logger.error("[track_pick] remove menu failed: #{e.class}: #{e.message}")
    {}
  end

  def ephemeral(text)
    { type: 4, data: { content: text, flags: 64 } }
  end
end
