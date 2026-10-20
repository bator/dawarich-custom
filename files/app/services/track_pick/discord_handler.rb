# frozen_string_literal: true

# Handles the "trackpick:<date>:..." controls on the existing GTFS Discord
# gateway. Hooked in by config/initializers/track_pick_discord.rb (prepend on
# Gtfs::Discord::InteractionHandler#prepare); every other click goes to the
# original handler unchanged.
#
# - whole-day / inner-city / rides select: UPDATE_MESSAGE with the re-stated controls, no copy;
# - Confirm: copy (whole day from one user, optionally the inner city from another, and per
#   ride a user's GPS or the timetable line), then the message collapses to one line;
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
    unless TrackPick::Config.allowed_discord_user_ids.include?(user['id'].to_s)
      return Plan.new(ephemeral(Gtfs::Discord::InteractionHandler.not_allowed_text))
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

    values = Array(interaction.dig('data', 'values')).map(&:to_s)
    action = parse(match[2], values)
    return Plan.new(ephemeral('Ismeretlen választás.')) unless action

    case action[:kind]
    when :select
      rows, line = TrackPick::Message.restate(Array(interaction.dig('message', 'components')),
                                              date:, day: action[:day], bp: action[:bp], picks: action[:picks],
                                              note: action[:note])
      Plan.new({ type: UPDATE_MESSAGE, data: { content: line, components: rows } })
    when :confirm
      return Plan.new(ephemeral('Előbb válaszd ki az egész napot.')) unless action[:day]

      Plan.new({ type: DEFERRED_UPDATE_MESSAGE },
               -> { work(interaction, date, action[:day], action[:bp], action[:picks], user) })
    when :skip
      Plan.new({ type: DEFERRED_UPDATE_MESSAGE }, -> { work(interaction, date, 'skip', 'same', {}, user) })
    end
  end

  private

  # rest: the custom_id after the date; values: the picked select values
  def parse(rest, values)
    value = values.first.to_s
    pick = TrackPick::Config::PICK
    bp_pick = TrackPick::Config::BP_PICK
    case rest
    when nil # older single select: value = user id | skip
      return nil unless TrackPick::Config::CHOICE.match?(value)

      value == 'skip' ? { kind: :skip } : { kind: :confirm, day: value, bp: 'same', picks: {} }
    when 'skip' then { kind: :skip }
    when /\A\d+\z/ then { kind: :confirm, day: rest, bp: 'same', picks: {} } # older per-user button
    when /\A(d|b|r|ok):([^:]+):([^:]+):([^:]+)\z/ # current: full state in every control
      action, day, bp, picks = Regexp.last_match.captures
      picks = TrackPick::Message.decode_picks(picks)
      return nil unless pick.match?(day) && bp_pick.match?(bp) && picks

      day = nil if day == '-'
      case action
      when 'd'
        return nil unless value.match?(/\A\d+\z/)

        { kind: :select, day: value, bp:, picks: }
      when 'b'
        return nil unless bp_pick.match?(value)

        { kind: :select, day:, bp: value, picks: }
      when 'r'
        chosen, conflict = TrackPick::Message.picks_from_values(values)
        return { kind: :select, day:, bp:, picks:, note: 'Útonként egy forrást válassz.' } if conflict

        { kind: :select, day:, bp:, picks: chosen }
      when 'ok' then { kind: :confirm, day:, bp:, picks: }
      end
    when /\Ad:(.+)\z/ # 2026-10-18 morning format, no rides
      bp = Regexp.last_match(1)
      return nil unless bp_pick.match?(bp) && value.match?(/\A\d+\z/)

      { kind: :select, day: value, bp:, picks: {} }
    when /\Ab:(.+)\z/
      day = Regexp.last_match(1)
      return nil unless pick.match?(day) && bp_pick.match?(value)

      { kind: :select, day: (day == '-' ? nil : day), bp: value, picks: {} }
    when /\Aok:([^:]+):([^:]+)\z/
      day = Regexp.last_match(1)
      bp = Regexp.last_match(2)
      return nil unless pick.match?(day) && bp_pick.match?(bp)

      { kind: :confirm, day: (day == '-' ? nil : day), bp:, picks: {} }
    end
  end

  def work(interaction, date, day, bp, picks, user)
    actor = (user['global_name'].presence || user['username'].presence || 'ismeretlen').to_s
    target = TrackPick::Config.target_user
    TrackPick::Config.with_decision_lock(date) { decide(interaction, date, day, bp, picks, actor, target) }
  rescue StandardError => e
    Rails.logger.error("[track_pick] #{e.class}: #{e.message}")
    { error: "Nem sikerült (#{e.class.name.demodulize}); részletek a bot logjában." } # A2: no e.message to Discord
  end

  def decide(interaction, date, day, bp, picks, actor, target)
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
      rides = ride_picks(date, picks, users)
      return { error: 'Ismeretlen vagy nem használható út.' } unless rides

      inserted = copy(date, day_user, bp_user, rides, target)
      label = pick_label(day_user, bp_user, rides, target)
      hidden = @hidden.to_i.positive? ? ", #{@hidden} saját pont elrejtve" : ''
      text = "#{date}: #{label} → #{TrackPick::Config.handle(target)}, " \
             "#{inserted.positive? ? "#{inserted} új pont" : 'nincs másolás'}#{hidden} (#{actor})."
    end
    TrackPick::Config.record_decision!(date, choice: label, user: actor, inserted:)
    Rails.logger.info("[track_pick] #{text}")
    $stdout.puts("[track_pick] #{text}")
    Gtfs::Discord::Client.new.edit_message(interaction['channel_id'], interaction.dig('message', 'id'),
                                           TrackPick::Message.done_payload(text))
    {}
  end

  # [[segment, user | :gtfs], ...] in time order, or nil when a pick is not a ride of that day
  def ride_picks(date, picks, users)
    return [] if picks.empty?

    from, to = TrackPick::Config.day_range(date)
    segments = TransitSegment.where(id: picks.keys.map(&:to_i), user_id: users.values.map(&:id))
                             .where(started_at: from...to).where.not(status: 'rejected').index_by { |s| s.id.to_s }
    picks.map do |seg_id, src|
      seg = segments[seg_id] or return nil
      if src == 'g'
        return nil unless TrackPick::GtfsPoints.new(date, seg).usable?

        [seg, :gtfs]
      else
        (u = users[src]) ? [seg, u] : (return nil)
      end
    end.sort_by { |seg, _| seg.started_at }
  end

  # Whole day from day_user (the inner city from bp_user when given); a picked ride's time
  # comes from its own source instead, and the target's own points in that time are hidden
  # (TrackPick::Hider, anomaly flag, nothing deleted). (Copier returns 0 when the source is
  # the target; a ride picked from the target itself keeps its own points.)
  def copy(date, day_user, bp_user, rides, target)
    windows = rides.map { |seg, _| [seg.started_at, seg.ended_at] }
    replaced = rides.reject { |_, src| src.is_a?(User) && src.id == target.id }
                    .map { |seg, _| [seg.started_at, seg.ended_at] }
    hider = TrackPick::Hider.new(date, target)
    hidden = []
    inserted = ActiveRecord::Base.transaction do
      hidden = hider.hide(replaced)
      base = if bp_user
               TrackPick::Copier.new(date, day_user, target, scope: :outside, except: windows).call +
                 TrackPick::Copier.new(date, bp_user, target, scope: :inside, except: windows).call
             else
               TrackPick::Copier.new(date, day_user, target, except: windows).call
             end
      base + rides.sum do |seg, src|
        if src == :gtfs
          TrackPick::GtfsPoints.new(date, seg, target).call
        else
          TrackPick::Copier.new(date, src, target, window: [seg.started_at, seg.ended_at]).call
        end
      end
    end
    hider.rebuild(hidden:, inserted:)
    @hidden = hidden.size
    inserted
  end

  def pick_label(day_user, bp_user, rides, target)
    label = "#{TrackPick::Config.handle(day_user)}#{day_user.id == target.id ? ' (marad)' : ''}"
    label = "#{label} (egész nap) + #{TrackPick::Config.handle(bp_user)} (belváros)" if bp_user
    return label if rides.empty?

    parts = rides.map do |seg, src|
      "#{seg.route_short_name}: #{src == :gtfs ? 'menetrendi vonal' : TrackPick::Config.handle(src)}"
    end
    "#{label}; utak: #{parts.join(', ')}"
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
