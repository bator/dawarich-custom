# frozen_string_literal: true

# The map image attached to a ride's Discord message, or nil when maps are
# off or anything goes wrong (the message is then sent without the image).
module Gtfs::Discord::RideImage
  module_function

  def filename(segment)
    "ride-#{segment.id}.png"
  end

  def call(segment, renderer: nil)
    return nil unless Gtfs::Discord::Config.map_enabled?

    map = Gtfs::Discord::RideMap.new(segment).call
    return nil if map.empty?

    data = (renderer || Gtfs::Discord::MapRenderer.new).render(map, style: style(segment), color: color(segment))
    Gtfs::Discord::Client::Upload.new(filename(segment), data, 'image/png')
  rescue StandardError => e
    Rails.logger.warn("[GTFS discord] map image for segment #{segment.id} failed: #{e.class}: #{e.message}")
    nil
  end

  # The line's own colour (Gtfs::RouteColors); the status is the line style.
  def color(segment)
    Gtfs::RouteColors.for_segment(segment).color
  end

  def style(segment)
    return :rejected if segment.rejected?

    Gtfs::Discord::Config.show_uncertain?(segment) ? :uncertain : :line
  end
end
