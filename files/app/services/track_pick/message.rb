# frozen_string_literal: true

# Discord payload of the daily comparison: one compact embed with one sheet image
# (one row per GTFS-matched ride: the three users' GPS in that time window + the
# timetable line, same bounding box), a whole-day select, an inner-city select, a
# per-ride select (a user's GPS or the timetable line for that ride), Confirm and Skip. Picking in a select only re-renders the controls
# (UPDATE_MESSAGE); nothing is copied until Confirm. After a decision the message
# collapses to one line (no embed, no image, no controls), like the GTFS ride panel.
module TrackPick::Message
  module_function

  PRIMARY = 1
  SECONDARY = 2
  SUCCESS = 3
  SELECT = 3
  BUTTON = 2
  ROW = 1
  SHEET_SUFFIX = 'sheet'

  def payload(comparison, sheet: nil, rides: [])
    stats = comparison.call
    date = comparison.date
    footer = if rides.any?
               'Soronként egy út: 1–3 a GPS abban az időablakban, A/B/… a menetrendi útvonal, közös kivágás. ' \
                 'Zöld pötty = kezdés, piros = vége.'
             else
               'Aznap nincs GTFS-szel azonosított út: 1–3 az egész nap, közös kivágás.'
             end
    embed = { title: "Track-választás – #{date.iso8601} → #{TrackPick::Config.handle(TrackPick::Config.target_user)}",
              description: [summary(comparison), ride_lines(rides)].reject(&:blank?).join("\n\n"),
              color: 0x0057B8,
              footer: { text: footer } }
    embed[:image] = { url: "attachment://#{sheet_filename(date)}" } if sheet
    { content: nil, embeds: [embed], components: components(date, stats, rides), allowed_mentions: { parse: [] } }
  end

  # one line per user: whole day | inner city
  def summary(comparison)
    zone = TrackPick::Config.zone
    target = TrackPick::Config.target_user
    comparison.call.each_with_index.map do |s, i|
      name = "**#{i + 1}** #{TrackPick::Config.handle(s.user)}#{s.user.id == target.id ? ' (cél)' : ''}"
      next "#{name} – nincs pont" if s.count.zero?

      span = "#{Time.zone.at(s.first_ts).in_time_zone(zone).strftime('%H:%M')}–" \
             "#{Time.zone.at(s.last_ts).in_time_zone(zone).strftime('%H:%M')}"
      bp = s.bp_times.size
      bp_text = bp > 1 ? "#{bp} p, #{s.bp_median_gap} s" : 'nincs'
      "#{name} – #{s.count} p, #{format('%.1f', s.km)} km, #{span}, #{s.gaps} szünet · belv.: #{bp_text}"
    end.join("\n")
  end

  def ride_lines(rides)
    zone = TrackPick::Config.zone
    rides.map do |r|
      s = r.segment
      span = "#{Time.zone.at(s.started_at).in_time_zone(zone).strftime('%H:%M')}–" \
             "#{Time.zone.at(s.ended_at).in_time_zone(zone).strftime('%H:%M')}"
      note = { 'straight' => ' (nincs menetrendi alak, csak egyenes: nem választható)',
               'stops' => ' (a megállókon át, alak nélkül)',
               'shape-other' => ' (alak egy mai, azonos megállós járatból)', nil => ' (nincs útvonal)' }[r.line_source]
      "**#{r.label}** #{s.route_short_name}, #{s.boarding_stop_name} → #{s.alighting_stop_name}, #{span}#{note}"
    end.join("\n")
  end

  # The pick travels in every control's custom_id ("state"), so a click needs no storage:
  #   trackpick:<date>:<action>:<day>:<bp>:<rides>   action d | b | r | ok
  #   day = user id or "-", bp = user id or "same",
  #   rides = "-" or "<segment id><g | u<user id>>" joined by "." (g = timetable line)
  # A select click replaces its own part; Confirm carries the whole pick.
  def state_id(date, action, day, bp, picks)
    "trackpick:#{date.iso8601}:#{action}:#{day || '-'}:#{bp}:#{encode_picks(picks)}"
  end

  def encode_picks(picks)
    return '-' if picks.empty?

    picks.sort_by { |seg, _| seg.to_i }.map { |seg, src| "#{seg}#{src == 'g' ? 'g' : "u#{src}"}" }.join('.')
  end

  # {segment id => 'g' | user id}, nil if malformed
  def decode_picks(text)
    return {} if text == '-'

    text.split('.').each_with_object({}) do |part, h|
      m = /\A(\d+)(?:(g)|u(\d+))\z/.match(part) or return nil
      h[m[1]] = m[2] || m[3]
    end
  end

  # values of the rides select ("<segment id>:g" / "<segment id>:u<user id>") -> [picks, conflict]
  def picks_from_values(values)
    picks = {}
    conflict = false
    values.each do |v|
      m = /\A(\d+):(?:(g)|u(\d+))\z/.match(v.to_s) or next
      conflict ||= picks.key?(m[1])
      picks[m[1]] = m[2] || m[3]
    end
    [picks, conflict]
  end

  def ride_value(segment_id, src) = "#{segment_id}:#{src == 'g' ? 'g' : "u#{src}"}"

  # rides: TrackPick::MapImage::Ride (line_source set by the sheet)
  def components(date, stats, rides = [], day: nil, bp: 'same', picks: {})
    target = TrackPick::Config.target_user
    day_menu = {
      type: SELECT, custom_id: state_id(date, 'd', day, bp, picks), placeholder: 'Egész nap: kié legyen?',
      min_values: 1, max_values: 1,
      options: stats.each_with_index.map do |s, i|
        own = s.user.id == target.id
        { label: "#{i + 1} – #{TrackPick::Config.handle(s.user)}#{own ? ' (marad)' : ''}".truncate(100),
          value: s.user.id.to_s, default: day == s.user.id.to_s,
          description: "#{s.count} pont, #{format('%.1f', s.km)} km#{own ? ' – nincs másolás' : ''}".truncate(100) }
      end
    }
    bp_menu = {
      type: SELECT, custom_id: state_id(date, 'b', day, bp, picks), placeholder: 'Belváros: ugyanaz, mint az egész nap',
      min_values: 1, max_values: 1,
      options: [{ label: 'Ugyanaz, mint az egész nap', value: 'same', default: bp == 'same' }] +
        stats.each_with_index.map do |s, i|
          { label: "#{i + 1}b – #{TrackPick::Config.handle(s.user)} belvárosa".truncate(100),
            value: s.user.id.to_s, default: bp == s.user.id.to_s,
            description: "#{s.bp_times.size} pont a belvárosban".truncate(100) }
        end
    }
    rows = [{ type: ROW, components: [day_menu] }, { type: ROW, components: [bp_menu] }]
    ride_opts = ride_options(date, stats, rides, picks)
    if ride_opts.any?
      rows << { type: ROW, components: [{
        type: SELECT, custom_id: state_id(date, 'r', day, bp, picks),
        placeholder: 'Utak: kinek a nyoma vagy a menetrendi vonal (nem kötelező)',
        min_values: 0, max_values: [ride_opts.size, 25].min, options: ride_opts
      }] }
    end
    rows << { type: ROW, components: [
      { type: BUTTON, style: SUCCESS, label: 'Jóváhagyás', custom_id: state_id(date, 'ok', day, bp, picks),
        disabled: day.nil? },
      { type: BUTTON, style: SECONDARY, label: 'Kihagyás', custom_id: "trackpick:#{date.iso8601}:skip" }
    ] }
    rows
  end

  # per ride: each user's GPS in the ride's time, and the timetable line when it is a real one
  def ride_options(date, stats, rides, picks)
    rides.flat_map do |r|
      seg = r.segment
      users = stats.each_with_index.filter_map do |s, i|
        n = s.times.count { |ts| ts.between?(seg.started_at, seg.ended_at) }
        next if n < 2

        { label: "#{r.label} – #{i + 1} #{TrackPick::Config.handle(s.user)} nyoma".truncate(100),
          value: ride_value(seg.id, s.user.id.to_s), default: picks[seg.id.to_s] == s.user.id.to_s,
          description: "#{seg.route_short_name}: #{n} pont az út idején".truncate(100) }
      end
      gtfs = TrackPick::GtfsPoints.new(date, seg)
      if TrackPick::RideLine::USABLE.include?(r.line_source) && (n = gtfs.samples.size).positive?
        users << { label: "#{r.label} – menetrendi vonal (#{seg.route_short_name})".truncate(100),
                   value: ride_value(seg.id, 'g'), default: picks[seg.id.to_s] == 'g',
                   description: "kb. #{n} pont a vonal mentén, #{seg.boarding_stop_name} → " \
                                "#{seg.alighting_stop_name}".truncate(100) }
      end
      users
    end.first(25)
  end

  # Re-states the controls of a posted message for a new pick, from the message's own
  # components (no stats needed, answers well inside Discord's 3 s). Returns [components, line].
  def restate(components, date:, day:, bp:, picks:, note: nil)
    prefix = "trackpick:#{date.iso8601}:"
    labels = { rides: [] }
    rows = components.map do |row|
      row.merge('components' => Array(row['components']).map do |c|
        action = c['custom_id'].to_s.delete_prefix(prefix)[/\A(d|b|r|ok):/, 1]
        next c unless action

        out = c.merge('custom_id' => state_id(date, action, day, bp, picks))
        case action
        when 'd'
          labels[:day] = c['options'].find { |o| o['value'] == day }&.dig('label')
          out['options'] = c['options'].map { |o| o.merge('default' => o['value'] == day) }
        when 'b'
          labels[:bp] = c['options'].find { |o| o['value'] == bp }&.dig('label')
          out['options'] = c['options'].map { |o| o.merge('default' => o['value'] == bp) }
        when 'r'
          chosen = picks.map { |seg, src| ride_value(seg, src) }
          labels[:rides] = c['options'].select { |o| chosen.include?(o['value']) }.map { |o| o['label'] }
          out['options'] = c['options'].map { |o| o.merge('default' => chosen.include?(o['value'])) }
        when 'ok'
          out['disabled'] = day.nil?
        end
        out
      end)
    end
    [rows, [note, pick_line(labels, day:, bp:)].compact.join(' ')]
  end

  def pick_line(labels, day:, bp:)
    return 'Válassz egész napot is, utána jóváhagyhatod.' unless day && labels[:day]

    line = "Kiválasztva: #{labels[:day]} (egész nap)"
    line += " + #{labels[:bp]}" if bp != 'same' && bp != day && labels[:bp]
    line += " · Utak: #{labels[:rides].join(', ')}" if labels[:rides].any?
    "#{line}. A Jóváhagyás után kerül át."
  end

  # --- segment pick (since 2026-11-08, TrackPick::Segments) -------------------------------
  # One select of "segment × source" (a segment not picked keeps the target's own points),
  # Ajánlott elfogadása, Jóváhagyás, Kihagyás. No whole-day pick. Custom ids:
  #   trackpick:<date>:s:<picks>    the select, carrying the current choice
  #   trackpick:<date>:sok:<picks>  Jóváhagyás
  #   trackpick:<date>:rec          Ajánlott elfogadása (the recommendations saved with the list)
  # picks as in encode_picks, keyed by segment number: "2u8.4g".
  CIRCLED = %w[① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ ⑩].freeze

  def segment_payload(comparison, segments, sheet: nil)
    date = comparison.date
    embed = { title: "Track-választás – #{date.iso8601} → #{TrackPick::Config.handle(TrackPick::Config.target_user)}",
              description: [summary(comparison), segment_lines(segments)].reject(&:blank?).join("\n\n"),
              color: 0x0057B8,
              footer: { text: 'Soronként egy szakasz, fentről lefelé ①, ②, …: 1–3 a GPS abban az időben, ' \
                              'A a menetrendi vonal. Amit nem választasz, az a saját nyomod marad.' } }
    embed[:image] = { url: "attachment://#{sheet_filename(date)}" } if sheet
    { content: nil, embeds: [embed], components: segment_components(date, segments),
      allowed_mentions: { parse: [] } }
  end

  def segment_lines(segments)
    zone = TrackPick::Config.zone
    segments.map do |seg|
      span = "#{Time.zone.at(seg.from).in_time_zone(zone).strftime('%H:%M')}–" \
             "#{Time.zone.at(seg.to).in_time_zone(zone).strftime('%H:%M')}"
      "**#{CIRCLED[seg.index - 1]}** #{span} · #{seg.title} · ajánlott: #{recommended_label(seg)}"
    end.join("\n")
  end

  def recommended_label(seg)
    return 'nincs, marad' if seg.recommended.nil?
    return 'A menetrendi vonal' if seg.recommended == 'g'

    i = seg.sources.index { |s| s.user.id.to_s == seg.recommended }
    s = seg.sources[i]
    own = s.user.id == TrackPick::Config.target_user.id
    "#{i + 1} #{TrackPick::Config.handle(s.user)}#{own ? ' (marad)' : ''} (#{(s.coverage * 100).round} % lefedés)"
  end

  def segment_components(date, segments, picks = {})
    opts = segment_options(segments, picks)
    rows = []
    if opts.any?
      rows << { type: ROW, components: [{
        type: SELECT, custom_id: "trackpick:#{date.iso8601}:s:#{encode_picks(picks)}",
        placeholder: 'Szakaszok: kié legyen? (amit nem választasz, marad)',
        min_values: 0, max_values: opts.size, options: opts
      }] }
    end
    rows << { type: ROW, components: [
      { type: BUTTON, style: PRIMARY, label: 'Ajánlott elfogadása', custom_id: "trackpick:#{date.iso8601}:rec",
        disabled: segments.none? { |s| copies?(s.recommended) } },
      { type: BUTTON, style: SUCCESS, label: 'Jóváhagyás', custom_id: "trackpick:#{date.iso8601}:sok:#{encode_picks(picks)}",
        disabled: picks.empty? },
      { type: BUTTON, style: SECONDARY, label: 'Kihagyás', custom_id: "trackpick:#{date.iso8601}:skip" }
    ] }
    rows
  end

  # a recommendation that copies something (not the target's own points)
  def copies?(src) = src.present? && src != TrackPick::Config.target_user.id.to_s

  # per segment: every other source with points in that time, and the timetable line of a ride
  def segment_options(segments, picks)
    target = TrackPick::Config.target_user
    segments.flat_map do |seg|
      mark = CIRCLED[seg.index - 1]
      opts = seg.sources.each_with_index.filter_map do |s, i|
        next if s.user.id == target.id || s.count < 2

        src = s.user.id.to_s
        { label: "#{mark} – #{i + 1} #{TrackPick::Config.handle(s.user)}".truncate(100),
          value: ride_value(seg.index, src), default: picks[seg.index.to_s] == src,
          description: "#{seg.title} · #{s.count} p, #{(s.coverage * 100).round} % lefedés" \
                       "#{seg.recommended == src ? ' · ajánlott' : ''}".truncate(100) }
      end
      if seg.gtfs
        opts << { label: "#{mark} – A menetrendi vonal".truncate(100), value: ride_value(seg.index, 'g'),
                  default: picks[seg.index.to_s] == 'g',
                  description: "#{seg.title}#{seg.recommended == 'g' ? ' · ajánlott' : ''}".truncate(100) }
      end
      opts
    end.first(25)
  end

  # Re-states a posted segment message for a new choice from its own components. => [components, line]
  def restate_segments(components, date:, picks:, note: nil)
    prefix = "trackpick:#{date.iso8601}:"
    chosen = picks.map { |seg, src| ride_value(seg, src) }
    labels = []
    rows = components.map do |row|
      row.merge('components' => Array(row['components']).map do |c|
        action = c['custom_id'].to_s.delete_prefix(prefix)[/\A(s|sok):/, 1]
        next c unless action

        if action == 's'
          labels = c['options'].select { |o| chosen.include?(o['value']) }.map { |o| o['label'] }
          c.merge('custom_id' => "#{prefix}s:#{encode_picks(picks)}",
                  'options' => c['options'].map { |o| o.merge('default' => chosen.include?(o['value'])) })
        else
          c.merge('custom_id' => "#{prefix}sok:#{encode_picks(picks)}", 'disabled' => picks.empty?)
        end
      end)
    end
    line = if labels.any?
             "Kiválasztva: #{labels.join(', ')}. A többi szakasz marad. A Jóváhagyás után kerül át."
           else
             'Nincs kiválasztott szakasz: válassz a listából, vagy fogadd el az ajánlottat.'
           end
    [rows, [note, line].compact.join(' ')]
  end

  def files(date, sheet)
    return [] unless sheet

    [Gtfs::Discord::Client::Upload.new(sheet_filename(date), sheet, 'image/png')]
  end

  def sheet_filename(date)
    "track-pick-#{date.iso8601}-#{SHEET_SUFFIX}.png"
  end

  def decided_line(decided)
    t = (Time.zone.parse(decided['time'].to_s)&.in_time_zone(TrackPick::Config.zone)&.strftime('%H:%M') rescue nil)
    copied = decided['inserted'].to_i.positive? ? " (#{decided['inserted']} pont átmásolva)" : ''
    "Már eldöntve#{t ? " #{t}-kor" : ''}: #{decided['choice']}#{copied}"
  end

  # one line, no embed, no image, no controls (attachments: [] drops the uploaded sheet)
  def done_payload(text)
    { content: text, embeds: [], attachments: [], components: [], allowed_mentions: { parse: [] } }
  end
end
