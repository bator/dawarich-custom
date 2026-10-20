# frozen_string_literal: true

require 'chunky_png'

# Draws the static map image of a ride (Gtfs::Discord::RideMap) as a PNG:
# OSM raster tiles stitched and lightened, the matched line in the line's
# own colour (Gtfs::RouteColors) with a casing (white; plus a thin dark edge
# around light colours such as M1 yellow) and the GPS trace as a thin dark
# line between the casing and the line (where the trace follows the line,
# the line keeps its colour; where it leaves it, the trace shows): lines
# only, no dots or stop markers. The ride's status is the line style, not
# its colour: solid (pending/approved), dashed in the line colour
# (uncertain), greyed out (rejected). Plus the attribution
# ("© OpenStreetMap-közreműködők" or "© OpenStreetMap contributors", in the
# bot's language) in the bottom-right corner (the tiles' licence requires
# it). Pure Ruby (chunky_png), no system libraries.
class Gtfs::Discord::MapRenderer
  WIDTH = 800
  HEIGHT = 450
  PADDING = 48
  TILE = 256
  MAX_ZOOM = 16
  MIN_ZOOM = 3
  MAX_LAT = 85.05112878

  C = ChunkyPNG::Color
  COLORS = {
    background: C.from_hex('#e8e6e1'), fade: C.rgba(255, 255, 255, 80), casing: C::WHITE,
    edge: C.from_hex('#3a3a3a'), rejected_grey: C.from_hex('#a3a3a3'),
    # dark, not blue: blue is a line colour (M3, BKK buses, MÁV S trains)
    gps: C.from_hex('#1e1e1e'),
    label_box: C.rgba(255, 255, 255, 200), label: C.from_hex('#333333')
  }.freeze

  DEFAULT_LINE = '#6B7280'
  # dash pattern along an uncertain line, in pixels of the centre line; the round
  # caps (radius 4) add 4 px at each end, so it shows ~18 px of line and ~8 px of gap
  DASH_ON = 10
  DASH_OFF = 16
  REJECTED_GREY = 0.75 # share of grey mixed into a rejected line's colour

  attr_reader :zoom

  def initialize(tiles: Gtfs::Discord::TileSource.new, width: WIDTH, height: HEIGHT)
    @tiles = tiles
    @width = width
    @height = height
    @discs = {}
  end

  # style: :line (solid), :uncertain (dashed) or :rejected (greyed out);
  # color: the line colour, '#RRGGBB'.
  def render(map, style: :line, color: DEFAULT_LINE, attribution: Gtfs::Discord::Texts.t('attribution'))
    raise ArgumentError, 'nothing to draw' if map.empty?
    raise ArgumentError, "unknown style #{style}" unless %i[line uncertain rejected].include?(style)

    place(map.coordinates)
    canvas = ChunkyPNG::Image.new(@width, @height, COLORS[:background])
    draw_tiles(canvas)
    canvas.pixels.map! { |pixel| C.compose_quick(COLORS[:fade], pixel) }
    draw_ride(canvas, map, line_style(color, style))
    draw_attribution(canvas, attribution)
    canvas.to_blob(color_mode: ChunkyPNG::COLOR_TRUECOLOR, compression: Zlib::BEST_COMPRESSION)
  end

  # Pixel position of a coordinate in the last rendered image.
  def pixel(lon, lat)
    x, y = world(lon, lat, @zoom)
    [x - @origin_x, y - @origin_y]
  end

  private

  # The line colour, the casing layers under it and whether it is dashed.
  def line_style(color, style)
    hex = Gtfs::RouteColors.hex(color) || DEFAULT_LINE
    hex = greyed(hex) if style == :rejected
    under = [[COLORS[:casing], 6]]
    under << [COLORS[:edge], 5] if Gtfs::RouteColors.light?(hex)
    under << [COLORS[:casing], 4] if style == :uncertain # the gaps between the dashes
    { color: C.from_hex(hex), under:, dashed: style == :uncertain }
  end

  def greyed(hex)
    rgb = C.from_hex(hex)
    grey = COLORS[:rejected_grey]
    mixed = %i[r g b].map { |c| ((C.send(c, rgb) * (1 - REJECTED_GREY)) + (C.send(c, grey) * REJECTED_GREY)).round }
    format('#%<r>02X%<g>02X%<b>02X', r: mixed[0], g: mixed[1], b: mixed[2])
  end

  def draw_ride(canvas, map, style)
    # all casings first, so no casing covers another run's line
    style[:under].each do |color, radius|
      map.line.each { |run| stroke(canvas, run, color, radius) }
    end
    # the trace under the line: on the line the line colour wins
    map.gps.each { |run| stroke(canvas, run, COLORS[:gps], 1) }
    dash = style[:dashed] ? [DASH_ON, DASH_OFF] : nil
    map.line.each { |run| stroke(canvas, run, style[:color], 4, dash:) }
  end

  def draw_attribution(canvas, text)
    font = Gtfs::Discord::PixelFont
    box_w = font.width(text) + 6
    box_h = font::HEIGHT + 4
    left = @width - box_w
    top = @height - box_h
    (top...@height).each do |y|
      (left...@width).each { |x| canvas.compose_pixel(x, y, COLORS[:label_box]) }
    end
    font.draw(canvas, text, left + 3, top + 2, COLORS[:label])
  end

  # Highest zoom at which everything fits inside the padding, centred.
  def place(coordinates)
    @zoom = MAX_ZOOM.downto(MIN_ZOOM).find { |z| fits?(coordinates, z) } || MIN_ZOOM
    xs, ys = coordinates.map { |lon, lat| world(lon, lat, @zoom) }.transpose
    @origin_x = (((xs.min + xs.max) / 2.0) - (@width / 2.0)).round
    @origin_y = (((ys.min + ys.max) / 2.0) - (@height / 2.0)).round
  end

  def fits?(coordinates, zoom)
    xs, ys = coordinates.map { |lon, lat| world(lon, lat, zoom) }.transpose
    xs.max - xs.min <= @width - (2 * PADDING) && ys.max - ys.min <= @height - (2 * PADDING)
  end

  # Web Mercator pixel coordinates at a zoom level.
  def world(lon, lat, zoom)
    size = TILE * (2**zoom)
    rad = lat.clamp(-MAX_LAT, MAX_LAT) * Math::PI / 180
    x = (lon + 180.0) / 360.0 * size
    y = (1 - (Math.log(Math.tan(rad) + (1 / Math.cos(rad))) / Math::PI)) / 2 * size
    [x, y]
  end

  def draw_tiles(canvas)
    count = 2**@zoom
    (@origin_x.div(TILE)..(@origin_x + @width - 1).div(TILE)).each do |tx|
      (@origin_y.div(TILE)..(@origin_y + @height - 1).div(TILE)).each do |ty|
        next unless ty.between?(0, count - 1)

        tile = load_tile(tx % count, ty)
        paste(canvas, tile, (tx * TILE) - @origin_x, (ty * TILE) - @origin_y) if tile
      end
    end
  end

  def load_tile(tile_x, tile_y)
    blob = @tiles.fetch(@zoom, tile_x, tile_y)
    tile = blob && ChunkyPNG::Image.from_blob(blob)
    tile if tile && tile.width == TILE && tile.height == TILE
  rescue ChunkyPNG::Exception, Zlib::Error
    nil
  end

  def paste(canvas, tile, left, top)
    sx = [-left, 0].max
    sy = [-top, 0].max
    w = [TILE - sx, @width - (left + sx)].min
    h = [TILE - sy, @height - (top + sy)].min
    return if w <= 0 || h <= 0

    canvas.replace!(tile.crop(sx, sy, w, h), left + sx, top + sy)
  end

  # Lines only: a run of a single point (e.g. cut by a privacy zone) would be
  # a dot and is skipped. dash: [on, off] pixels along the run, or nil.
  def stroke(canvas, run, color, radius, dash: nil)
    points = run.map { |lon, lat| pixel(lon, lat) }
    return if points.size < 2

    travelled = 0.0
    points.each_cons(2) do |(x0, y0), (x1, y1)|
      length = Math.hypot(x1 - x0, y1 - y0)
      steps = [(x1 - x0).abs, (y1 - y0).abs].max.ceil.clamp(1, 10_000)
      (0..steps).each do |i|
        t = i.fdiv(steps)
        next if dash && ((travelled + (length * t)) % dash.sum) >= dash.first

        stamp(canvas, x0 + ((x1 - x0) * t), y0 + ((y1 - y0) * t), radius, color)
      end
      travelled += length
    end
  end

  def stamp(canvas, left, top, radius, color)
    cx = left.round
    cy = top.round
    disc(radius).each { |ox, oy| canvas.set_pixel_if_within_bounds(cx + ox, cy + oy, color) }
  end

  def disc(radius)
    range = (-radius..radius).to_a
    @discs[radius] ||= range.product(range).select { |ox, oy| (ox * ox) + (oy * oy) <= (radius * radius) + radius }
  end
end
