# frozen_string_literal: true

# PNG maps of a day, reusing the GTFS Discord tile renderer without changing it:
# - build_sheet: everything in one image for the Discord message (see below);
# - build_each: one per user, own bounding box over all of the day's points;
# - build_budapest: one per user with Budapest points, all with the SAME bbox
#   (union of the three users' Budapest points) so they are comparable.
# Thin line (3 px, white outline), every fix as a small dark dot, start = green, end = red.
# CT 146 (Atlas) serves no raster tiles / static map to the LAN (only
# /api/v1/map-match|coverage|version, data/tiles empty), so tiles stay OSM raster;
# crispness comes from a large canvas at native tile scale.
class TrackPick::MapImage < Gtfs::Discord::MapRenderer
  Layers = Struct.new(:layers, :bbox) do
    def coordinates = bbox || layers.flat_map { |l| l[:coords] }
    def empty? = coordinates.empty?
  end
  MAX_POINTS = 6000
  WIDTH = 1600
  HEIGHT = 1200
  DOT = ChunkyPNG::Color.from_hex('#1e1e1e')

  def self.build_each(comparison)
    comparison.call.each_with_index.filter_map do |s, i|
      next if s.coords.size < 2

      [s, render_one(s.coords, i)]
    end
  end

  # fixed inner-city bbox, same for every user
  def self.build_budapest(comparison)
    bp = TrackPick::Comparison::BUDAPEST
    bbox = [[bp[:lon].begin, bp[:lat].begin], [bp[:lon].end, bp[:lat].end]]
    comparison.call.each_with_index.filter_map do |s, i|
      next if s.bp_coords.size < 2

      [s, render_runs(s.bp_runs, i, bbox:)]
    end
  end

  # One PNG for the whole choice: whole-day maps (1, 2, 3) on top, inner-city maps (1b, 2b, 3b)
  # below, same column = same user. A user without (inner-city) points gets a grey panel.
  PANEL = [800, 600].freeze
  SMALL_PANEL = [600, 450].freeze
  GUTTER = 6
  SHEET_BG = ChunkyPNG::Color.from_hex('#ffffff')
  EMPTY_BG = ChunkyPNG::Color.from_hex('#d9d9d9')

  def self.build_sheet(comparison)
    png = sheet(comparison, *PANEL)
    return png if png.bytesize <= UPLOAD_LIMIT - UPLOAD_MARGIN

    sheet(comparison, *SMALL_PANEL)
  end

  def self.sheet(comparison, panel_w, panel_h)
    stats = comparison.call.first(3)
    bp = TrackPick::Comparison::BUDAPEST
    bbox = [[bp[:lon].begin, bp[:lat].begin], [bp[:lon].end, bp[:lat].end]]
    cols = [stats.size, 1].max
    canvas = ChunkyPNG::Image.new((cols * panel_w) + ((cols + 1) * GUTTER), (2 * panel_h) + (3 * GUTTER), SHEET_BG)
    with_size(panel_w, panel_h) do
      stats.each_with_index do |s, i|
        x = GUTTER + (i * (panel_w + GUTTER))
        whole = s.coords.size >= 2 ? render_one(s.coords, i) : nil
        inner = s.bp_coords.size >= 2 ? render_runs(s.bp_runs, i, bbox:) : nil
        paste(canvas, whole, x, GUTTER, panel_w, panel_h, (i + 1).to_s, i)
        paste(canvas, inner, x, (2 * GUTTER) + panel_h, panel_w, panel_h, "#{i + 1}b", i)
      end
    end
    canvas.to_blob(color_mode: ChunkyPNG::COLOR_TRUECOLOR, compression: Zlib::BEST_COMPRESSION)
  end

  def self.paste(canvas, png, left, top, width, height, label, index)
    panel = png ? ChunkyPNG::Image.from_blob(png) : ChunkyPNG::Image.new(width, height, EMPTY_BG)
    canvas.replace!(panel, left, top)
    Label.draw(canvas, label, left + 12, top + 12, ChunkyPNG::Color.from_hex(TrackPick::Config::COLORS[index % 3]))
  end

  # Big panel label ("1", "2b"): 5x7 glyphs scaled up on a coloured badge with a white border.
  module Label
    SCALE = 6
    PAD = 10
    GLYPHS = {
      '1' => %w[..#.. .##.. ..#.. ..#.. ..#.. ..#.. .###.],
      '2' => %w[.###. #...# ....# ...#. ..#.. .#... #####],
      '3' => %w[####. ....# ....# .###. ....# ....# ####.],
      'b' => %w[#.... #.... ####. #...# #...# #...# ####.]
    }.freeze

    module_function

    def draw(canvas, text, left, top, color)
      glyphs = text.each_char.filter_map { |c| GLYPHS[c] }
      return if glyphs.empty?

      w = (glyphs.size * 5 * SCALE) + ((glyphs.size - 1) * SCALE) + (2 * PAD)
      h = (7 * SCALE) + (2 * PAD)
      canvas.rect(left - 3, top - 3, left + w + 2, top + h + 2, ChunkyPNG::Color::WHITE, ChunkyPNG::Color::WHITE)
      canvas.rect(left, top, left + w - 1, top + h - 1, color, color)
      x = left + PAD
      glyphs.each do |rows|
        rows.each_with_index do |row, gy|
          row.each_char.with_index do |cell, gx|
            next unless cell == '#'

            px = x + (gx * SCALE)
            py = top + PAD + (gy * SCALE)
            canvas.rect(px, py, px + SCALE - 1, py + SCALE - 1, ChunkyPNG::Color::WHITE, ChunkyPNG::Color::WHITE)
          end
        end
        x += 6 * SCALE
      end
    end
  end

  UPLOAD_LIMIT = 10 * 1024 * 1024 # bot upload limit per message
  UPLOAD_MARGIN = 256 * 1024 # payload_json + multipart overhead

  # A8: if the PNGs exceed the limit, re-render at 1200x900; if still too big, drop the inner-city maps.
  def self.fit_upload_limit(comparison, images, budapest)
    fits = ->(list) { list.sum { |_, png| png.bytesize } <= UPLOAD_LIMIT - UPLOAD_MARGIN }
    return [images, budapest] if fits.call(images + budapest)

    small = with_size(1200, 900) { [build_each(comparison), build_budapest(comparison)] }
    return small if fits.call(small.flatten(1))

    warn 'track_pick: maps over 10 MB even at 1200x900, inner-city maps dropped'
    [small.first, []]
  end

  def self.with_size(width, height)
    old = [@width, @height]
    @width, @height = width, height
    yield
  ensure
    @width, @height = old
  end

  def self.canvas_size = [@width || WIDTH, @height || HEIGHT]

  def self.render_one(coords, index, bbox: nil) = render_runs([coords], index, bbox:)

  def self.render_runs(runs, index, bbox: nil)
    total = runs.sum(&:size)
    step = [(total / MAX_POINTS.to_f).ceil, 1].max
    thin = runs.map do |run|
      t = run.each_slice(step).map(&:first)
      t << run.last unless t.last == run.last
      t
    end
    new(width: canvas_size[0], height: canvas_size[1])
      .render(Layers.new(thin.map { |c| { coords: c, color: TrackPick::Config::COLORS[index % 3] } }, bbox))
  end

  private

  def line_style(_color, _style) = {}

  def draw_ride(canvas, map, _style)
    map.layers.each { |l| stroke(canvas, l[:coords], COLORS[:casing], 2) }
    map.layers.each do |l|
      stroke(canvas, l[:coords], ChunkyPNG::Color.from_hex(l[:color]), 1)
      l[:coords].each { |lon, lat| x, y = pixel(lon, lat); stamp(canvas, x, y, 1, DOT) }
    end
    marker(canvas, map.layers.first[:coords].first, ChunkyPNG::Color.from_hex('#1A9E3F'))
    marker(canvas, map.layers.last[:coords].last, ChunkyPNG::Color.from_hex('#E4002B'))
  end

  def marker(canvas, (lon, lat), color)
    x, y = pixel(lon, lat)
    stamp(canvas, x, y, 9, ChunkyPNG::Color::WHITE)
    stamp(canvas, x, y, 7, color)
  end
end
