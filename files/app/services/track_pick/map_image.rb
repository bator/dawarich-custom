# frozen_string_literal: true

# PNG maps of a day, reusing the GTFS Discord tile renderer without changing it:
# build_sheet: everything in one image for the Discord message, per GTFS ride (see below).
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

  # One PNG for the whole choice. One row per ride the GTFS matcher found that day (any of
  # the three users; the same route overlapping in time is one ride): panels 1-3 = each
  # user's GPS in the ride's time window, 4 (A, B, ...) = the timetable line with its two
  # stops, all four with the same bounding box so they compare. Without a ride: one row,
  # the three whole days with a common bounding box. A user without points gets a grey panel.
  PANEL = [600, 450].freeze
  SMALL_PANEL = [480, 360].freeze
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
    png = sheet(comparison, rides, *PANEL)
    return png if png.bytesize <= UPLOAD_LIMIT - UPLOAD_MARGIN

    sheet(comparison, rides, *SMALL_PANEL)
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

  # RideMap result drawn by the GTFS renderer, forced onto the shared bbox
  BoxedRide = Struct.new(:line, :gps, :board, :alight, :bbox) do
    def coordinates = bbox
    def empty? = bbox.blank?
  end

  def self.render_line(segment, map, bbox)
    w, h = canvas_size
    Gtfs::Discord::MapRenderer.new(width: w, height: h)
                              .render(BoxedRide.new(map.line, [], map.board, map.alight, bbox),
                                      style: :line, color: Gtfs::RouteColors.for_segment(segment).color)
  rescue StandardError => e
    Rails.logger.warn("[track_pick] gtfs panel of segment #{segment.id} failed: #{e.class}: #{e.message}")
    nil
  end

  def self.paste(canvas, png, left0, top, width, height, label, badge, col:)
    left = left0 + (col * (width + GUTTER))
    panel = png ? ChunkyPNG::Image.from_blob(png) : ChunkyPNG::Image.new(width, height, EMPTY_BG)
    canvas.replace!(panel, left, top)
    Label.text(canvas, 'nincs adat', left + (width / 2), top + (height / 2), EMPTY_TEXT) unless png
    Label.draw(canvas, label, left + 10, top + 10, badge)
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
