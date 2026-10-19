# frozen_string_literal: true

# Formatting shared by the transit analysis pages.
module TransitHelper
  # Lucide icon per GTFS mode for the pages; the Discord messages keep their
  # emoji (Gtfs::Discord::MessageBuilder::EMOJI). The bundled Lucide subset
  # has no tram-front or train-front-tunnel, so every rail mode is train-front.
  MODE_ICON = { 'bus' => 'bus', 'tram' => 'train-front', 'metro' => 'train-front', 'rail' => 'train-front',
                'suburban' => 'train-front', 'ferry' => 'ship', 'other' => 'map-pin' }.freeze

  # Decorative Lucide icon: the label next to it (visible or sr-only) carries the meaning.
  def transit_icon(name, css = 'w-4 h-4')
    icon(name, class: "#{css} shrink-0", aria: { hidden: true })
  end

  def transit_mode_icon(mode, css = 'w-4 h-4')
    transit_icon(MODE_ICON.fetch(mode.to_s, 'map-pin'), css)
  end

  # "1 h 5 min" / "25 min"
  def transit_duration(seconds)
    return '–' if seconds.nil?

    minutes = (seconds / 60.0).round
    return t('transit_segments.card.minutes', count: minutes) if minutes < 60

    t('transit_segments.index.hours_minutes', hours: minutes / 60, minutes: minutes % 60)
  end

  # "+3 min" / "−1 min" / "0 min"; nil when unknown
  def transit_delay(seconds)
    return '–' if seconds.nil?

    minutes = (seconds / 60.0).round
    sign = if minutes.positive? then '+'
           elsif minutes.negative? then '−'
           else ''
           end
    "#{sign}#{t('transit_segments.card.minutes', count: minutes.abs)}"
  end

  # [background, text] hex colours of a ride's line: the operator's route
  # colour (Gtfs::RouteColors via Api::TransitSegmentSerializer.colors_for),
  # else the mode colour.
  def transit_line_colors(segment, colors)
    color, text_color = colors[[segment.feed_id, segment.route_gtfs_id]]
    hex = ->(value) { (v = value.to_s.delete_prefix('#')).match?(/\A\h{6}\z/) ? "##{v.upcase}" : nil }
    background = hex.call(color) || Api::TransitSegmentSerializer::DEFAULT_COLORS.fetch(segment.mode)
    [background, hex.call(text_color) || Gtfs::RouteColors.readable_text(background)]
  end

  # Line badge in the route colour.
  def transit_line_badge(segment, colors, extra_class: '')
    background, foreground = transit_line_colors(segment, colors)
    content_tag(:span, class: "badge font-bold gap-1 border-0 min-w-12 justify-center #{extra_class}",
                       style: "background-color: #{background}; color: #{foreground}",
                       title: t("transit_modes.#{segment.mode}")) do
      safe_join([transit_mode_icon(segment.mode, 'w-3.5 h-3.5'),
                 content_tag(:span, t("transit_modes.#{segment.mode}"), class: 'sr-only'),
                 segment.route_short_name || segment.route_long_name])
    end
  end
end
