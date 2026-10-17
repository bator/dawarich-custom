# frozen_string_literal: true

# The colour a ride's line is drawn in (Discord map image, web transit layer,
# Discord embed bar), in the operator's own scheme:
#
# 1. the feed's route_color (BKK: M1 yellow, M2 red, M3 blue, M4 green, HÉV
#    H5-H9, trams and the cogwheel 60 yellow, buses blue, trolleys red,
#    night buses black; MÁV: suburban S light blue, G lime, Z yellow, IR green);
# 2. MÁV trains the feed leaves uncoloured (IC, EC, railjet, Sz, named and
#    numbered trains): MÁV's own train-category colours as on the MÁV Plusz
#    map (InterCity dark blue, InterRégió/sebesvonat green, személyvonat
#    light blue, zónázó yellow; see docs/gtfs.md "Line colours"), by the
#    category at the start of the train's name; other MÁV trains dark blue
#    (MÁV Plusz draws every train on a dark blue pictogram);
# 3. else a default per mode.
#
# The text colour is the feed's route_text_color, else black or white,
# whichever is readable on the line colour.
module Gtfs::RouteColors
  Color = Struct.new(:color, :text_color, :source, keyword_init: true)

  MODE_DEFAULTS = {
    'bus' => '#009EE3', 'tram' => '#F2B705', 'metro' => '#E41F18', 'rail' => '#1F4E9C',
    'suburban' => '#2E8B57', 'ferry' => '#8E44AD', 'other' => '#6B7280'
  }.freeze

  MAV_INTERCITY = '#1B467D'
  # [pattern on the first word of the train name, colour, text colour, category]
  MAV_CATEGORIES = [
    [/\A(IC\+?|EC|EN|ICE|RJX?|railjet)\z/i, MAV_INTERCITY, '#FFFFFF', 'intercity'],
    [/\A(IR|ER|Gy|Sv|Sebes)\z/i, '#29803C', '#FFFFFF', 'interregio'],
    [/\A(Sz|VESz|S\d+)\z/, '#00A0E3', '#FFFFFF', 'szemely'],
    [/\AZ\d+\z/, '#FECC00', '#000000', 'zonazo'],
    [/\AG\d+\z/, '#B0CB1F', '#FFFFFF', 'gyorsitott']
  ].freeze
  MAV_TRAIN_DEFAULT = Color.new(color: MAV_INTERCITY, text_color: '#FFFFFF', source: 'mav:train').freeze

  module_function

  # feed_key: the feed's key; name: route short name, else long name.
  def resolve(feed_key:, mode:, name:, color:, text_color:)
    own = hex(color)
    return Color.new(color: own, text_color: hex(text_color) || readable_text(own), source: 'feed') if own
    return mav_train(name) if mav_feed?(feed_key) && mode == 'rail'

    fallback = MODE_DEFAULTS.fetch(mode, MODE_DEFAULTS['other'])
    Color.new(color: fallback, text_color: readable_text(fallback), source: 'mode')
  end

  # {[feed_id, route_gtfs_id] => Color} for many segments in one query.
  def for_segments(segments)
    pairs = segments.map { |s| [s.feed_id, s.route_gtfs_id] }.uniq.reject { |_, route| route.blank? }
    return {} if pairs.empty?

    rows = Gtfs::Route.joins(:feed)
                      .where('gtfs_routes.version = gtfs_feeds.active_version')
                      .where(feed_id: pairs.map(&:first).uniq, gtfs_id: pairs.map(&:last).uniq)
                      .pluck(:feed_id, :gtfs_id, 'gtfs_feeds.key', :route_type, :short_name, :long_name, :color,
                             :text_color)
    rows.to_h do |feed_id, route, key, type, short, long, color, text|
      [[feed_id, route], resolve(feed_key: key, mode: TransitSegment.mode_for(type), name: short.presence || long,
                                 color:, text_color: text)]
    end
  end

  # The colour of one segment, also when its route is gone from the timetable.
  def for_segment(segment)
    for_segments([segment])[[segment.feed_id, segment.route_gtfs_id]] ||
      resolve(feed_key: segment.feed&.key, mode: segment.mode,
              name: segment.route_short_name.presence || segment.route_long_name, color: nil, text_color: nil)
  end

  def mav_feed?(key)
    ENV.fetch('GTFS_MAV_FEED_KEYS', 'mav').split(',').map(&:strip).include?(key.to_s)
  end

  def mav_train(name)
    word = name.to_s.strip.split(/\s+/).first.to_s
    _, color, text, category = MAV_CATEGORIES.find { |pattern, *| word.match?(pattern) }
    return MAV_TRAIN_DEFAULT unless color

    Color.new(color:, text_color: text, source: "mav:#{category}")
  end

  def hex(value)
    value = value.to_s.strip.delete_prefix('#')
    value.match?(/\A\h{6}\z/) ? "##{value.upcase}" : nil
  end

  # Relative luminance (WCAG) of '#RRGGBB', 0 (black) .. 1 (white).
  def luminance(color)
    r, g, b = hex(color).delete_prefix('#').scan(/../).map { |c| c.to_i(16) / 255.0 }
    lin = ->(c) { c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
    (0.2126 * lin.call(r)) + (0.7152 * lin.call(g)) + (0.0722 * lin.call(b))
  end

  def light?(color)
    luminance(color) > Float(ENV.fetch('GTFS_ROUTE_COLOR_LIGHT_LUMINANCE', '0.45'))
  end

  def readable_text(color)
    light?(color) ? '#000000' : '#FFFFFF'
  end

  # Casing around a line: dark around light colours (M1 yellow, Z yellow) so
  # they stay visible on the light basemap, else white.
  def casing(color)
    light?(color) ? '#3A3A3A' : '#FFFFFF'
  end
end
