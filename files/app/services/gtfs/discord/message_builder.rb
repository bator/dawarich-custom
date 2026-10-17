# frozen_string_literal: true

# The Discord message of one ride (Hungarian, as requested). While the ride
# waits for a decision: line, stops, times, confidence, the map image of the
# ride (an attachment, see Gtfs::Discord::RideImage), the Jóváhagyom /
# Elutasítom buttons and, when the matcher scored other trips, a select menu
# to switch the ride to one of them (Gtfs::SegmentReview `choose`, like
# "Másik járat" on the web).
# Once it is confirmed or rejected the message collapses to one line (whose
# ride, from where to where) with only a Visszavonom button: no embed, no
# image (attachments: []), no select menu. Undo brings the full message back.
class Gtfs::Discord::MessageBuilder
  CUSTOM_ID = /\Agtfs_seg:(confirm|reject|reset|choose):(\d+)\z/
  CHOICE_VALUE = /\A(\d+):(.+)\z/
  MAX_CHOICES = 25
  EMOJI = { 'bus' => '🚌', 'tram' => '🚋', 'metro' => '🚇', 'rail' => '🚆', 'suburban' => '🚈',
            'ferry' => '⛴️', 'other' => '🚏' }.freeze
  MODE_NAME = { 'bus' => 'busz', 'tram' => 'villamos', 'metro' => 'metró', 'rail' => 'vonat',
                'suburban' => 'HÉV', 'ferry' => 'hajó', 'other' => 'járat' }.freeze
  CHOSEN_TEXT = '🔁 Másik járatra cserélve'
  CHOSEN_WAITING = 'jóváhagyásra vár'
  # Neutral texts for a ride that is gone or hidden: no line, stops, times,
  # map or name stay in the channel (review H3).
  DELETED_TEXT = '🗑️ Ez a menet törölve lett.'
  HIDDEN_TEXT = '🔒 Ez a menet már nem látható.'

  BUTTON_STYLE = { primary: 1, secondary: 2, success: 3, danger: 4, link: 5 }.freeze
  COMPACT_MARK = { 'confirmed' => '✅', 'rejected' => '❌' }.freeze
  COMPACT_REJECTED = 'elutasítva'
  # The optional details (line, date and time) are added only while the line
  # stays this short, so the collapsed message is a single line on Discord.
  COMPACT_MAX = 100

  # Confirmed and rejected rides get the one-line message without a map image.
  def self.compact?(segment)
    COMPACT_MARK.key?(segment.status)
  end

  def self.custom_id(action, segment_id)
    "gtfs_seg:#{action}:#{segment_id}"
  end

  # Select menu value of an alternative trip: "<feed id>:<trip id>".
  def self.choice_value(alternative)
    "#{alternative['feed_id']}:#{alternative['trip_gtfs_id']}"
  end

  # => [feed_id, trip_gtfs_id] or nil
  def self.parse_choice(value)
    match = CHOICE_VALUE.match(value.to_s)
    match && [match[1], match[2]]
  end

  # Replacement for a message whose ride was deleted (rematch, deleted
  # points, privacy zone, deleted user): text only, image and buttons removed.
  def self.deleted_payload
    neutral_payload(DELETED_TEXT)
  end

  # Replacement while the ride is hidden (privacy zone, matching turned off).
  def self.hidden_payload
    neutral_payload(HIDDEN_TEXT)
  end

  def self.neutral_payload(text)
    { content: text, embeds: [], components: [], attachments: [], allowed_mentions: { parse: [] } }
  end

  # image: file name of the map image attached to this request (always an
  # attachment, so its size never changes between edits).
  def initialize(segment, actor: nil, image: nil)
    @segment = segment
    @actor = actor
    @image_url = ("attachment://#{image}" if image)
    @zone = ActiveSupport::TimeZone[segment.user.timezone_iana] || Time.zone
  end

  def payload
    return compact_payload if self.class.compact?(@segment)

    rows = [{ type: 1, components: buttons }]
    rows << { type: 1, components: [select_menu] } if choices.any?
    { content: result_line, embeds: [embed], components: rows, allowed_mentions: { parse: [] } }
  end

  private

  # One text line and the undo button; attachments: [] removes the map image
  # of the full message on this edit.
  def compact_payload
    undo = button('Visszavonom', :secondary, self.class.custom_id(:reset, @segment.id))
    { content: compact_line, embeds: [], components: [{ type: 1, components: [undo] }], attachments: [],
      allowed_mentions: { parse: [] } }
  end

  # "✅ Anna Kiss utazása: Kelenföld → Érd felső · vonat 9057 · 10. 08. 07:10"
  # "❌ Anna Kiss utazása: Kelenföld → Érd felső · elutasítva · vonat 9057 · 10. 08. 07:10"
  def compact_line
    s = @segment
    text = "#{COMPACT_MARK.fetch(s.status)} #{Gtfs::Discord::Config.user_label(s.user)} utazása: " \
           "#{s.boarding_stop_name} → #{s.alighting_stop_name}"
    text += " · #{COMPACT_REJECTED}" if s.rejected?
    [line, @zone.at(s.started_at).strftime('%m. %d. %H:%M')].each do |detail|
      break if text.length + detail.length + 3 > COMPACT_MAX

      text += " · #{detail}"
    end
    text
  end

  # A switch to another trip is not an approval: "🔁 Másik járatra cserélve
  # (crusand), jóváhagyásra vár" until it is confirmed or rejected (then the
  # message collapses, #compact_payload).
  def result_line
    return nil unless @segment.auto? && @segment.user_chosen?

    who = " (#{@actor})" if @actor.present?
    "#{CHOSEN_TEXT}#{who}, #{CHOSEN_WAITING}"
  end

  def embed
    s = @segment
    hex = Gtfs::RouteColors.for_segment(s).color.delete_prefix('#')
    embed = {
      author: { name: "👤 #{Gtfs::Discord::Config.user_label(s.user)} utazása".truncate(250) },
      title: "#{EMOJI.fetch(s.mode)} #{line} · #{s.boarding_stop_name} → #{s.alighting_stop_name}".truncate(250),
      url: map_url,
      color: hex.to_i(16),
      description: description_lines.join("\n"),
      footer: { text: footer_text }
    }
    embed[:image] = { url: @image_url } if @image_url
    embed
  end

  # The OpenStreetMap attribution is drawn into the map image itself.
  def footer_text
    "Dawarich · menet ##{@segment.id} · #{@segment.feed&.name || @segment.feed&.key}"
  end

  def line
    [MODE_NAME.fetch(@segment.mode), @segment.route_short_name || @segment.route_long_name].compact.join(' ')
  end

  def description_lines
    s = @segment
    debug = s.debug || {}
    started = @zone.at(s.started_at)
    ended = @zone.at(s.ended_at)
    lines = ["🕒 #{started.strftime('%Y. %m. %d.')} #{started.strftime('%H:%M')}–#{ended.strftime('%H:%M')} " \
             "(#{((s.ended_at - s.started_at) / 60.0).round} perc)"]
    schedule = "#{clock(debug['scheduled_departure_secs'])}–#{clock(debug['scheduled_arrival_secs'])}"
    lines << "🗓️ Menetrend: #{schedule}#{delay_text}"
    uncertain = ' · ⚠️ bizonytalan' if Gtfs::Discord::Config.show_uncertain?(s)
    lines << "🎯 Megbízhatóság: #{(s.confidence * 100).round}%#{uncertain}"
    lines.concat(reasons(debug))
    lines << "➡️ Irány: #{s.headsign}" if s.headsign.present?
    lines
  end

  def delay_text
    return '' unless @segment.delay_reliable?

    minutes = (@segment.debug['delay_secs'].to_i / 60.0).round
    return ' · pontosan' if minutes.zero?

    minutes.positive? ? " · késés kb. #{minutes} perc" : " · kb. #{-minutes} perccel korábban"
  end

  def reasons(debug)
    reasons = []
    if Array(debug['caps']).include?('no_intermediate_stops')
      reasons << '• nincs köztes megálló, az útvonal nem ellenőrizhető'
    end
    reasons << '• a megállókban nem állt meg (lehet autó/bicikli)' if Array(debug['caps']).include?('no_dwell')
    if debug['ambiguous'] && debug['alternatives'].present?
      alts = debug['alternatives'].first(2).map do |a|
        "#{a['line'] || a['route_short_name']} (#{(a['confidence'].to_f * 100).round}%)"
      end
      reasons << "• más vonal is illeszkedik: #{alts.join(', ')}"
    end
    reasons << '• ugyanennek a vonalnak egy másik járata is illeszkedik' if debug['trip_ambiguous']
    reasons
  end

  def clock(secs)
    return '?' if secs.nil?

    format('%<h>02d:%<m>02d', h: (secs / 3600) % 24, m: (secs % 3600) / 60)
  end

  # Only for a ride without a decision (decided rides: #compact_payload).
  def buttons
    id = @segment.id
    [button('Jóváhagyom', :success, self.class.custom_id(:confirm, id)),
     button('Elutasítom', :danger, self.class.custom_id(:reject, id))]
  end

  # The other trips the matcher scored for this ride (only full v3 entries
  # can be chosen), the previously chosen trip included after a switch.
  def choices
    @choices ||= begin
      debug = @segment.debug || {}
      (Array(debug['alternatives']) + Array(debug['trip_alternatives']))
        .select { |alt| alt.key?('started_at') && alt['trip_gtfs_id'].present? && alt['feed_id'].present? }
        .uniq { |alt| self.class.choice_value(alt) }
        .first(MAX_CHOICES)
    end
  end

  def select_menu
    { type: 3, custom_id: self.class.custom_id(:choose, @segment.id), placeholder: 'Másik járat választása…',
      min_values: 1, max_values: 1, options: choices.map { |alt| choice_option(alt) } }
  end

  def choice_option(alt)
    line = alt['line'].presence || alt['route_short_name'].presence || alt['route_long_name'].presence || '?'
    times = if alt['scheduled_departure_secs']
              "#{clock(alt['scheduled_departure_secs'])}–#{clock(alt['scheduled_arrival_secs'])}"
            else
              [alt['started_at'], alt['ended_at']].map { |at| @zone.at(at.to_i).strftime('%H:%M') }.join('–')
            end
    { label: "#{line} · #{times} · #{(alt['confidence'].to_f * 100).round}%".truncate(100),
      description: "#{alt['boarding_stop_name']} → #{alt['alighting_stop_name']}".truncate(100),
      value: self.class.choice_value(alt).truncate(100, omission: '') }
  end

  def button(label, style, custom_id)
    { type: 2, style: BUTTON_STYLE.fetch(style), label:, custom_id: }
  end

  def map_url
    from = @zone.at(@segment.started_at - 600).iso8601
    to = @zone.at(@segment.ended_at + 600).iso8601
    "#{Gtfs::Discord::Config.app_url}/map/v2?#{URI.encode_www_form(start_at: from, end_at: to)}"
  end
end
