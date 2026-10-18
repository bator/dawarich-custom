# frozen_string_literal: true

# Discord payload of the daily comparison: one compact embed with one sheet image
# (whole-day maps 1-3 on top, inner-city maps 1b-3b below), a whole-day select, an
# inner-city select, Confirm and Skip. Picking in a select only re-renders the
# controls (UPDATE_MESSAGE); nothing is copied until Confirm. After a decision the
# message collapses to one line (no embed, no image, no controls), like the GTFS
# ride panel.
module TrackPick::Message
  module_function

  PRIMARY = 1
  SECONDARY = 2
  SUCCESS = 3
  SELECT = 3
  BUTTON = 2
  ROW = 1
  SHEET_SUFFIX = 'sheet'

  def payload(comparison, sheet: nil)
    stats = comparison.call
    date = comparison.date
    embed = { title: "Track-választás – #{date.iso8601} → #{TrackPick::Config.handle(TrackPick::Config.target_user)}",
              description: summary(comparison),
              color: 0x0057B8,
              footer: { text: 'Felül egész nap (1–3), alul belváros (1b–3b, közös bbox). ' \
                              'Zöld pötty = kezdés, piros = vége.' } }
    embed[:image] = { url: "attachment://#{sheet_filename(date)}" } if sheet
    { content: nil, embeds: [embed], components: components(date, stats), allowed_mentions: { parse: [] } }
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

  # day: picked whole-day user id (String) or nil; bp: inner-city user id or 'same'
  def components(date, stats, day: nil, bp: 'same')
    d = date.iso8601
    target = TrackPick::Config.target_user
    day_menu = {
      type: SELECT, custom_id: "trackpick:#{d}:d:#{bp}", placeholder: 'Egész nap: kié legyen?',
      min_values: 1, max_values: 1,
      options: stats.each_with_index.map do |s, i|
        own = s.user.id == target.id
        { label: "#{i + 1} – #{TrackPick::Config.handle(s.user)}#{own ? ' (marad)' : ''}".truncate(100),
          value: s.user.id.to_s, default: day == s.user.id.to_s,
          description: "#{s.count} pont, #{format('%.1f', s.km)} km#{own ? ' – nincs másolás' : ''}".truncate(100) }
      end
    }
    bp_menu = {
      type: SELECT, custom_id: "trackpick:#{d}:b:#{day || '-'}", placeholder: 'Belváros: ugyanaz, mint az egész nap',
      min_values: 1, max_values: 1,
      options: [{ label: 'Ugyanaz, mint az egész nap', value: 'same', default: bp == 'same' }] +
        stats.each_with_index.map do |s, i|
          { label: "#{i + 1}b – #{TrackPick::Config.handle(s.user)} belvárosa".truncate(100),
            value: s.user.id.to_s, default: bp == s.user.id.to_s,
            description: "#{s.bp_times.size} pont a belvárosban".truncate(100) }
        end
    }
    buttons = [
      { type: BUTTON, style: SUCCESS, label: 'Jóváhagyás', custom_id: "trackpick:#{d}:ok:#{day || '-'}:#{bp}",
        disabled: day.nil? },
      { type: BUTTON, style: SECONDARY, label: 'Kihagyás', custom_id: "trackpick:#{d}:skip" }
    ]
    [{ type: ROW, components: [day_menu] }, { type: ROW, components: [bp_menu] }, { type: ROW, components: buttons }]
  end

  # Re-states the controls of a posted message for a new pick, from the message's own
  # components (no stats needed, answers well inside Discord's 3 s). Returns [components, line].
  def restate(components, date:, day:, bp:)
    d = date.iso8601
    labels = {}
    rows = components.map do |row|
      row.merge('components' => Array(row['components']).map do |c|
        id = c['custom_id'].to_s
        if id.start_with?("trackpick:#{d}:d:")
          labels[:day] = c['options'].find { |o| o['value'] == day }&.dig('label')
          c.merge('custom_id' => "trackpick:#{d}:d:#{bp}",
                  'options' => c['options'].map { |o| o.merge('default' => o['value'] == day) })
        elsif id.start_with?("trackpick:#{d}:b:")
          labels[:bp] = c['options'].find { |o| o['value'] == bp }&.dig('label')
          c.merge('custom_id' => "trackpick:#{d}:b:#{day || '-'}",
                  'options' => c['options'].map { |o| o.merge('default' => o['value'] == bp) })
        elsif id.start_with?("trackpick:#{d}:ok:")
          c.merge('custom_id' => "trackpick:#{d}:ok:#{day || '-'}:#{bp}", 'disabled' => day.nil?)
        else
          c
        end
      end)
    end
    [rows, pick_line(labels, day:, bp:)]
  end

  def pick_line(labels, day:, bp:)
    return 'Válassz egész napot is, utána jóváhagyhatod.' unless day && labels[:day]

    line = "Kiválasztva: #{labels[:day]} (egész nap)"
    line += " + #{labels[:bp]}" if bp != 'same' && bp != day && labels[:bp]
    "#{line}. A Jóváhagyás után kerül át."
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
