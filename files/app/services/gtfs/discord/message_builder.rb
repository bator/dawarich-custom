# frozen_string_literal: true

# The Discord message of one ride, in the language picked on /transit/discord
# (Gtfs::Discord::Texts; Hungarian by default). While the ride waits for a
# decision: line, stops, times, confidence, the map image of the ride (an
# attachment, see Gtfs::Discord::RideImage), the approve / reject buttons and,
# when the matcher scored other trips, a select menu to switch the ride to one
# of them (Gtfs::SegmentReview `choose`, like "Másik járat" on the web).
# Once it is confirmed or rejected the message collapses to one line (whose
# ride, from where to where) with only an undo button: no embed, no image
# (attachments: []), no select menu. Undo brings the full message back.
class Gtfs::Discord::MessageBuilder
  CUSTOM_ID = /\Agtfs_seg:(confirm|reject|reset|choose):(\d+)\z/
  CHOICE_VALUE = /\A(\d+):(.+)\z/
  MAX_CHOICES = 25
  EMOJI = { 'bus' => '🚌', 'tram' => '🚋', 'metro' => '🚇', 'rail' => '🚆', 'suburban' => '🚈',
            'ferry' => '⛴️', 'other' => '🚏' }.freeze
  BUTTON_STYLE = { primary: 1, secondary: 2, success: 3, danger: 4, link: 5 }.freeze
  COMPACT_MARK = { 'confirmed' => '✅', 'rejected' => '❌' }.freeze
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
  # Neutral: no line, stops, times, map or name stay in the channel (review H3).
  def self.deleted_payload
    neutral_payload(Gtfs::Discord::Texts.t('deleted'))
  end

  # Replacement while the ride is hidden (privacy zone, matching turned off).
  def self.hidden_payload
    neutral_payload(Gtfs::Discord::Texts.t('hidden'))
  end

  def self.neutral_payload(text)
    { content: text, embeds: [], components: [], attachments: [], allowed_mentions: { parse: [] } }
  end

  # image: file name of the map image attached to this request (always an
  # attachment, so its size never changes between edits); locale: the
  # page's preview asks for each language, the bot uses the one picked.
  def initialize(segment, actor: nil, image: nil, locale: Gtfs::Discord::Config.locale)
    @segment = segment
    @actor = actor
    @image_url = ("attachment://#{image}" if image)
    @locale = locale
    @zone = ActiveSupport::TimeZone[segment.user.timezone_iana] || Time.zone
  end

  def payload
    return compact_payload if self.class.compact?(@segment)

    rows = [{ type: 1, components: buttons }]
    rows << { type: 1, components: [select_menu] } if choices.any?
    { content: result_line, embeds: [embed], components: rows, allowed_mentions: { parse: [] } }
  end

  # The full message (embed and buttons) even for a ride already decided:
  # /transit/discord shows what the message of a new ride looks like.
  def preview_payload
    { embeds: [embed], components: [{ type: 1, components: buttons }] }
  end

  private

  # One text line and the undo button; attachments: [] removes the map image
  # of the full message on this edit.
  def compact_payload
    undo = button(text('undo'), :secondary, self.class.custom_id(:reset, @segment.id))
    { content: compact_line, embeds: [], components: [{ type: 1, components: [undo] }], attachments: [],
      allowed_mentions: { parse: [] } }
  end

  # "✅ Anna Kiss utazása: Kelenföld → Érd felső · vonat 9057 · 10. 08. 07:10"
  # "❌ Anna Kiss's ride: Kelenföld → Érd felső · rejected · train 9057 · Oct 8 07:10"
  def compact_line
    s = @segment
    result = text('compact', mark: COMPACT_MARK.fetch(s.status), name: Gtfs::Discord::Config.user_label(s.user),
                             from: s.boarding_stop_name, to: s.alighting_stop_name)
    result += " · #{text('rejected')}" if s.rejected?
    [line, @zone.at(s.started_at).strftime(text('compact_time'))].each do |detail|
      break if result.length + detail.length + 3 > COMPACT_MAX

      result += " · #{detail}"
    end
    result
  end

  # A switch to another trip is not an approval: "🔁 Másik járatra cserélve
  # (crusand), jóváhagyásra vár" until it is confirmed or rejected (then the
  # message collapses, #compact_payload).
  def result_line
    return nil unless @segment.auto? && @segment.user_chosen?

    text('chosen', who: @actor.present? ? " (#{@actor})" : '')
  end

  def embed
    s = @segment
    hex = Gtfs::RouteColors.for_segment(s).color.delete_prefix('#')
    embed = {
      author: { name: text('ride_of', name: Gtfs::Discord::Config.user_label(s.user)).truncate(250) },
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
    text('footer', id: @segment.id, feed: @segment.feed&.name || @segment.feed&.key)
  end

  def line
    [text("mode.#{@segment.mode}"), @segment.route_short_name || @segment.route_long_name].compact.join(' ')
  end

  def description_lines
    s = @segment
    debug = s.debug || {}
    started = @zone.at(s.started_at)
    ended = @zone.at(s.ended_at)
    lines = [text('times', date: started.strftime(text('date')), from: started.strftime('%H:%M'),
                           to: ended.strftime('%H:%M'), minutes: ((s.ended_at - s.started_at) / 60.0).round)]
    schedule = "#{clock(debug['scheduled_departure_secs'])}–#{clock(debug['scheduled_arrival_secs'])}"
    lines << text('schedule', times: schedule, delay: delay_text)
    uncertain = Gtfs::Discord::Config.show_uncertain?(s) ? text('uncertain') : ''
    lines << text('confidence', percent: "#{(s.confidence * 100).round}%", uncertain:)
    lines.concat(reasons(debug))
    lines << text('headsign', headsign: s.headsign) if s.headsign.present?
    lines
  end

  def delay_text
    return '' unless @segment.delay_reliable?

    minutes = (@segment.debug['delay_secs'].to_i / 60.0).round
    return text('on_time') if minutes.zero?

    minutes.positive? ? text('late', minutes:) : text('early', minutes: -minutes)
  end

  def reasons(debug)
    reasons = []
    reasons << text('reason_no_intermediate') if Array(debug['caps']).include?('no_intermediate_stops')
    reasons << text('reason_no_dwell') if Array(debug['caps']).include?('no_dwell')
    if debug['ambiguous'] && debug['alternatives'].present?
      alts = debug['alternatives'].first(2).map do |a|
        "#{a['line'] || a['route_short_name']} (#{(a['confidence'].to_f * 100).round}%)"
      end
      reasons << text('reason_other_line', lines: alts.join(', '))
    end
    reasons << text('reason_other_trip') if debug['trip_ambiguous']
    reasons
  end

  def clock(secs)
    return '?' if secs.nil?

    format('%<h>02d:%<m>02d', h: (secs / 3600) % 24, m: (secs % 3600) / 60)
  end

  # Only for a ride without a decision (decided rides: #compact_payload).
  def buttons
    id = @segment.id
    [button(text('confirm'), :success, self.class.custom_id(:confirm, id)),
     button(text('reject'), :danger, self.class.custom_id(:reject, id))]
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
    { type: 3, custom_id: self.class.custom_id(:choose, @segment.id), placeholder: text('choose'),
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

  def text(key, **values)
    Gtfs::Discord::Texts.t(key, @locale, **values)
  end

  def map_url
    from = @zone.at(@segment.started_at - 600).iso8601
    to = @zone.at(@segment.ended_at + 600).iso8601
    "#{Gtfs::Discord::Config.app_url}/map/v2?#{URI.encode_www_form(start_at: from, end_at: to)}"
  end
end
