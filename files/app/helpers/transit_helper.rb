# frozen_string_literal: true

# Formatting shared by the transit analysis pages.
module TransitHelper
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
    [hex.call(color) || Api::TransitSegmentSerializer::DEFAULT_COLORS.fetch(segment.mode), hex.call(text_color) || '#FFFFFF']
  end

  # Line badge in the route colour.
  def transit_line_badge(segment, colors, extra_class: '')
    background, foreground = transit_line_colors(segment, colors)
    content_tag(:span, class: "badge font-bold gap-1 border-0 min-w-12 justify-center #{extra_class}",
                       style: "background-color: #{background}; color: #{foreground}",
                       title: t("transit_modes.#{segment.mode}")) do
      safe_join([content_tag(:span, Gtfs::Discord::MessageBuilder::EMOJI.fetch(segment.mode), class: 'text-xs', 'aria-hidden': true),
                 segment.route_short_name || segment.route_long_name])
    end
  end
end
