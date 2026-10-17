# frozen_string_literal: true

# Discord payload of the daily comparison: one button per source user + Skip.
module TrackPick::Message
  module_function

  PRIMARY = 1
  SECONDARY = 2
  SUCCESS = 3

  # images: [[stat, png], ...] from TrackPick::MapImage.build_each; one embed per map
  def payload(comparison, images: [], budapest: [])
    stats = comparison.call
    target = TrackPick::Config.target_user
    date = comparison.date.iso8601
    options = stats.map do |s|
      own = s.user.id == target.id
      { label: "#{TrackPick::Config.handle(s.user)}#{own ? ' (marad)' : ''}".truncate(100),
        value: s.user.id.to_s,
        description: "#{s.count} pont, #{format('%.1f', s.km)} km#{own ? ' – nincs másolás' : ''}".truncate(100) }
    end
    options << { label: 'Kihagyás', value: 'skip', description: 'Semmi sem kerül át' }
    menu = { type: 3, custom_id: "trackpick:#{date}", placeholder: 'Melyik track kerüljön át?',
             min_values: 1, max_values: 1, options: }
    embeds = [{ title: "Melyik track kerüljön #{TrackPick::Config.handle(target)} fiókjába? (#{date})",
                description: "#{comparison.to_text}\n\nA térképeken: zöld pötty = kezdés, piros = vége, apró sötét pöttyök = GPS-fixek. A belvárosi képek bboxa (fix) mindhárom felhasználónál ugyanaz.",
                color: 0x0057B8 }]
    images.each do |s, _png|
      i = comparison.call.index(s) # A1: same colour index as the map
      embeds << { title: "#{i + 1}. #{TrackPick::Config.handle(s.user)} – #{date} – #{s.count} pont, " \
                         "#{format('%.1f', s.km)} km",
                  color: TrackPick::Config::COLORS[i % 3].delete('#').to_i(16),
                  image: { url: "attachment://#{filename(s)}" } }
    end
    budapest.each do |s, _png|
      i = comparison.call.index(s)
      embeds << { title: "#{i + 1}b. #{TrackPick::Config.handle(s.user)} – belváros – #{s.bp_times.size} pont, " \
                         "medián #{s.bp_median_gap || '-'} s",
                  color: TrackPick::Config::COLORS[i % 3].delete('#').to_i(16),
                  image: { url: "attachment://#{filename(s, 'bp')}" } }
    end
    { embeds:, components: [{ type: 1, components: [menu] }], allowed_mentions: { parse: [] } }
  end

  def files(images, budapest = [])
    images.map { |s, png| Gtfs::Discord::Client::Upload.new(filename(s), png, 'image/png') } +
      budapest.map { |s, png| Gtfs::Discord::Client::Upload.new(filename(s, 'bp'), png, 'image/png') }
  end

  def filename(stat, suffix = nil)
    "track-pick-#{TrackPick::Config.handle(stat.user).gsub(/[^\w.-]/, '_')}#{"-#{suffix}" if suffix}.png"
  end

  def color_legend(stats)
    names = %w[piros kék zöld]
    stats.each_with_index.map { |s, i| "#{TrackPick::Config.handle(s.user)} = #{names[i % 3]}" }.join(', ')
  end

  def decided_line(decided)
    t = (Time.zone.parse(decided['time'].to_s)&.in_time_zone(TrackPick::Config.zone)&.strftime('%H:%M') rescue nil)
    copied = decided['inserted'].to_i.positive? ? " (#{decided['inserted']} pont átmásolva)" : ''
    "Már eldöntve#{t ? " #{t}-kor" : ''}: #{decided['choice']}#{copied}"
  end

  # embeds and their images stay as they are; only the buttons go away
  def done_payload(_original_embeds, text)
    { content: text, components: [] }
  end
end
