# frozen_string_literal: true

# PNG maps of a day, reusing the GTFS Discord tile renderer without changing it:
# build_sheet: everything in one image for the Discord message, per GTFS ride (see below).
# Thin anti-aliased line with a soft white halo, every fix as a small soft dot, start = green, end = red.
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

  # One PNG for the whole choice. One row per ride the GTFS matcher found that day (any of
  # the three users; the same route overlapping in time is one ride): panels 1-3 = each
  # user's GPS in the ride's time window, 4 (A, B, ...) = the timetable line with its two
  # stops, all four with the same bounding box so they compare. Without a ride: one row,
  # the three whole days with a common bounding box. A user without points gets a grey panel.
  # panel sizes, largest first: the first sheet under the upload limit is sent
  PANELS = [[1200, 900], [1000, 750], [800, 600], [600, 450]].freeze
  GUTTER = 6
  MAX_RIDES = 4
  RIDE_MARGIN = 180 # seconds of GPS shown before and after a ride
  RIDE_JOIN = 120 # the same route starting within this of another ride's end is the same ride
  SHEET_BG = ChunkyPNG::Color.from_hex('#ffffff')
  EMPTY_BG = ChunkyPNG::Color.from_hex('#d9d9d9')
  EMPTY_TEXT = ChunkyPNG::Color.from_hex('#7a7a7a')
  RIDE_LABELS = %w[A B C D].freeze
  Ride = Struct.new(:label, :segment, :from, :to, :line_source, keyword_init: true) # line_source: set by #sheet

  # rides of the day, oldest first, at most MAX_RIDES; segment = the best match of the ride
  def self.rides(comparison)
    from, to = TrackPick::Config.day_range(comparison.date)
    segs = TransitSegment.where(user_id: comparison.call.map { |s| s.user.id })
                         .where(started_at: from...to).where.not(status: 'rejected').order(:started_at).to_a
    groups = []
    segs.each do |seg|
      group = groups.find do |g|
        g.first.route_short_name == seg.route_short_name &&
          seg.started_at <= g.map(&:ended_at).max + RIDE_JOIN && seg.ended_at + RIDE_JOIN >= g.map(&:started_at).min
      end
      group ? group << seg : groups << [seg]
    end
    groups.first(MAX_RIDES).each_with_index.map do |g, i|
      best = g.max_by { |s| [s.status == 'confirmed' ? 1 : 0, s.confidence.to_f] }
      Ride.new(label: RIDE_LABELS[i], segment: best,
               from: g.map(&:started_at).min - RIDE_MARGIN, to: g.map(&:ended_at).max + RIDE_MARGIN)
    end
  end

  def self.build_sheet(comparison, rides = self.rides(comparison))
    png = nil
    PANELS.each do |w, h|
      png = sheet(comparison, rides, w, h)
      return png if png.bytesize <= UPLOAD_LIMIT - UPLOAD_MARGIN

      warn "track_pick: sheet at #{w}x#{h} panels is #{png.bytesize / 1024} KB, trying smaller"
    end
    png
  end

  def self.sheet(comparison, rides, panel_w, panel_h)
    stats = comparison.call.first(3)
    cols = rides.empty? ? [stats.size, 1].max : stats.size + 1
    rows = [rides.size, 1].max
    canvas = ChunkyPNG::Image.new((cols * panel_w) + ((cols + 1) * GUTTER), (rows * panel_h) + ((rows + 1) * GUTTER),
                                  SHEET_BG)
    with_size(panel_w, panel_h) do
      if rides.empty?
        bbox = bbox_of(stats.flat_map(&:coords))
        stats.each_with_index do |s, i|
          png = s.coords.size >= 2 && bbox ? render_one(s.coords, i, bbox:) : nil
          paste(canvas, png, GUTTER, GUTTER, panel_w, panel_h, (i + 1).to_s, color(i), col: i)
        end
      else
        rides.each_with_index do |ride, r|
          top = GUTTER + (r * (panel_h + GUTTER))
          line = ride_line(ride.segment)
          ride.line_source = line&.line_source
          windows = stats.map { |s| s.times.zip(s.coords).select { |ts, _| ts.between?(ride.from, ride.to) }.map(&:last) }
          bbox = bbox_of(windows.flatten(1) + (line ? line.coordinates : []))
          stats.each_with_index do |_s, i|
            png = windows[i].size >= 2 && bbox ? render_one(windows[i], i, bbox:) : nil
            paste(canvas, png, GUTTER, top, panel_w, panel_h, (i + 1).to_s, color(i), col: i)
          end
          gtfs = line && bbox ? render_line(ride.segment, line, bbox) : nil
          paste(canvas, gtfs, GUTTER, top, panel_w, panel_h, ride.label, ChunkyPNG::Color.from_hex('#333333'),
                col: stats.size)
        end
      end
    end
    canvas.to_blob(color_mode: ChunkyPNG::COLOR_TRUECOLOR, compression: Zlib::BEST_COMPRESSION)
  end

  def self.color(index) = ChunkyPNG::Color.from_hex(TrackPick::Config::COLORS[index % 3])

  # [[min lon, min lat], [max lon, max lat]] or nil
  def self.bbox_of(coords)
    return nil if coords.size < 2

    lons = coords.map(&:first)
    lats = coords.map(&:last)
    [[lons.min, lats.min], [lons.max, lats.max]]
  end

  # the timetable line and the two stops only (no GPS), or nil
  def self.ride_line(segment)
    map = Gtfs::Discord::RideMap.new(segment).call
    map.line.flatten(1).size >= 2 ? map : nil
  rescue StandardError => e
    Rails.logger.warn("[track_pick] ride map of segment #{segment.id} failed: #{e.class}: #{e.message}")
    nil
  end

  # the timetable line in its route colour, same anti-aliased style as the GPS (no fixes)
  def self.render_line(segment, map, bbox)
    hex = Gtfs::RouteColors.hex(Gtfs::RouteColors.for_segment(segment).color) || '#333333'
    layers = map.line.select { |run| run.size >= 2 }
                .map { |run| { coords: run, color: hex, width: 2.6, halo: 5.0, dots: false } }
    return nil if layers.empty?

    new(width: canvas_size[0], height: canvas_size[1]).render(Layers.new(layers, bbox))
  rescue StandardError => e
    Rails.logger.warn("[track_pick] gtfs panel of segment #{segment.id} failed: #{e.class}: #{e.message}")
    nil
  end

  def self.paste(canvas, png, left0, top, width, height, label, badge, col:)
    left = left0 + (col * (width + GUTTER))
    panel = png ? ChunkyPNG::Image.from_blob(png) : ChunkyPNG::Image.new(width, height, EMPTY_BG)
    canvas.replace!(panel, left, top)
    scale = [width / 120, 4].max # badge ~ 8 % of the panel height at any panel size
    Label.text(canvas, 'nincs adat', left + (width / 2), top + (height / 2), EMPTY_TEXT, scale:) unless png
    Label.draw(canvas, label, left + (2 * scale), top + (2 * scale), badge, scale:)
  end

  # Big panel label ("1", "2b"): 5x7 glyphs scaled up on a coloured badge with a white border.
  module Label
    SCALE = 5
    PAD = 8
    GLYPHS = {
      '1' => %w[..#.. .##.. ..#.. ..#.. ..#.. ..#.. .###.],
      '2' => %w[.###. #...# ....# ...#. ..#.. .#... #####],
      '3' => %w[####. ....# ....# .###. ....# ....# ####.],
      'b' => %w[#.... #.... ####. #...# #...# #...# ####.],
      'A' => %w[.###. #...# #...# ##### #...# #...# #...#],
      'B' => %w[####. #...# #...# ####. #...# #...# ####.],
      'C' => %w[.###. #...# #.... #.... #.... #...# .###.],
      'D' => %w[####. #...# #...# #...# #...# #...# ####.],
      'n' => %w[..... ..... #.##. ##..# #...# #...# #...#],
      'i' => %w[..#.. ..... .##.. ..#.. ..#.. ..#.. .###.],
      'c' => %w[..... ..... .###. #.... #.... #...# .###.],
      's' => %w[..... ..... .#### #.... .###. ....# ####.],
      'a' => %w[..... ..... .###. ....# .#### #...# .####],
      'd' => %w[....# ....# .##.# #..## #...# #...# .####],
      't' => %w[.#... .#... ###.. .#... .#... .#..# ..##.],
      ' ' => %w[..... ..... ..... ..... ..... ..... .....]
    }.freeze
    TEXT_SCALE = 4

    module_function

    # plain text (no badge), centred on (cx, cy)
    def text(canvas, text, cx, cy, color, scale: TEXT_SCALE)
      glyphs = text.each_char.filter_map { |c| GLYPHS[c] }
      w = (glyphs.size * 6 * scale) - scale
      x = cx - (w / 2)
      top = cy - (7 * scale / 2)
      glyphs.each do |rows|
        rows.each_with_index do |row, gy|
          row.each_char.with_index do |cell, gx|
            next unless cell == '#'

            px = x + (gx * scale)
            py = top + (gy * scale)
            canvas.rect(px, py, px + scale - 1, py + scale - 1, color, color)
          end
        end
        x += 6 * scale
      end
    end

    def draw(canvas, text, left, top, color, scale: SCALE)
      glyphs = text.each_char.filter_map { |c| GLYPHS[c] }
      return if glyphs.empty?

      pad = scale * PAD / SCALE
      w = (glyphs.size * 5 * scale) + ((glyphs.size - 1) * scale) + (2 * pad)
      h = (7 * scale) + (2 * pad)
      canvas.rect(left - 3, top - 3, left + w + 2, top + h + 2, ChunkyPNG::Color::WHITE, ChunkyPNG::Color::WHITE)
      canvas.rect(left, top, left + w - 1, top + h - 1, color, color)
      x = left + pad
      glyphs.each do |rows|
        rows.each_with_index do |row, gy|
          row.each_char.with_index do |cell, gx|
            next unless cell == '#'

            px = x + (gx * scale)
            py = top + pad + (gy * scale)
            canvas.rect(px, py, px + scale - 1, py + scale - 1, ChunkyPNG::Color::WHITE, ChunkyPNG::Color::WHITE)
          end
        end
        x += 6 * scale
      end
    end
  end

  UPLOAD_LIMIT = 10 * 1024 * 1024 # bot upload limit per message
  UPLOAD_MARGIN = 256 * 1024 # payload_json + multipart overhead

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

  # Anti-aliased: every pixel gets the colour at the share of it the shape covers.
  LINE_WIDTH = 1.8
  HALO_WIDTH = 4.2
  HALO = ChunkyPNG::Color.rgba(255, 255, 255, 190)
  FIX_RADIUS = 1.1
  FIX = ChunkyPNG::Color.rgba(30, 30, 30, 170)

  def draw_ride(canvas, map, _style)
    map.layers.each { |l| aa_polyline(canvas, l[:coords], HALO, l[:halo] || HALO_WIDTH) }
    map.layers.each do |l|
      aa_polyline(canvas, l[:coords], ChunkyPNG::Color.from_hex(l[:color]), l[:width] || LINE_WIDTH)
      l[:coords].each { |lon, lat| aa_disc(canvas, pixel(lon, lat), FIX_RADIUS, FIX) } unless l[:dots] == false
    end
    marker(canvas, map.layers.first[:coords].first, ChunkyPNG::Color.from_hex('#1A9E3F'))
    marker(canvas, map.layers.last[:coords].last, ChunkyPNG::Color.from_hex('#E4002B'))
  end

  def marker(canvas, (lon, lat), color)
    at = pixel(lon, lat)
    aa_disc(canvas, at, 6.5, ChunkyPNG::Color::WHITE)
    aa_disc(canvas, at, 5.0, color)
  end

  # One polyline: per pixel the largest coverage of any segment (joints do not darken).
  def aa_polyline(canvas, coords, color, width)
    pts = coords.map { |lon, lat| pixel(lon, lat) }
    return if pts.size < 2

    half = width / 2.0
    cover = {}
    pts.each_cons(2) do |(x0, y0), (x1, y1)|
      dx = x1 - x0
      dy = y1 - y0
      len2 = (dx * dx) + (dy * dy)
      xs = ([x0, x1].min - half - 1).floor.clamp(0, @width - 1)..([x0, x1].max + half + 1).ceil.clamp(0, @width - 1)
      ys = ([y0, y1].min - half - 1).floor.clamp(0, @height - 1)..([y0, y1].max + half + 1).ceil.clamp(0, @height - 1)
      ys.each do |py|
        xs.each do |px|
          t = len2.zero? ? 0.0 : ((((px - x0) * dx) + ((py - y0) * dy)) / len2).clamp(0.0, 1.0)
          c = half + 0.5 - Math.hypot(px - (x0 + (t * dx)), py - (y0 + (t * dy)))
          next if c <= 0

          key = (py * @width) + px
          c = 1.0 if c > 1
          cover[key] = c if c > (cover[key] || 0)
        end
      end
    end
    cover.each do |key, c|
      y, x = key.divmod(@width)
      canvas.compose_pixel(x, y, ChunkyPNG::Color.fade(color, (c * 255).round))
    end
  end

  def aa_disc(canvas, (cx, cy), radius, color)
    ((cy - radius - 1).floor..(cy + radius + 1).ceil).each do |py|
      ((cx - radius - 1).floor..(cx + radius + 1).ceil).each do |px|
        c = radius + 0.5 - Math.hypot(px - cx, py - cy)
        next if c <= 0

        canvas.compose_pixel(px, py, ChunkyPNG::Color.fade(color, ([c, 1.0].min * 255).round))
      end
    end
  end
end
