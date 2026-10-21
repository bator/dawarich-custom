# frozen_string_literal: true

# Fills the gaps of a walking or running frequent route (docs/corridors.md):
# inner stretches where few trips had a real fix (a tunnel, an underpass) get
# the pedestrian path Valhalla finds there, through the Atlas map-match
# endpoint the walk snap uses (GTFS_WALK_VALHALLA_URL, GTFS_WALK_VALHALLA_API
# atlas). Inside a gap the median is only a chord between the fixes on both
# sides, no shape to follow, so two anchor points of the line on each side are
# sent and map_snap routes between them. The path replaces the median from the
# last anchor before the gap to the first one after it when
#   - it is one continuous path (one leg) with both inner anchors matched,
#   - the inner anchors matched within ANCHOR_M of the line, and
#   - it is no detour: at most DETOUR_FACTOR x the median there + DETOUR_SLACK_M,
#     and nowhere farther than OFFSET_SHARE of the median's length (at least
#     OFFSET_MIN_M) from it (a path curving up to ~1.35x the chord stays within).
# Otherwise the median stays and the stretch remains a gap. Nothing is sent
# when CORRIDORS_FILL_GAPS=false, the walk snap's URL check or exclusion list
# refuses it (Gtfs::Walk::Config) or the server is unavailable (then not for
# the rest of the build either).
class Corridors::GapFiller
  G = Corridors::Geometry
  MODES = %w[walking running].freeze
  OUTER_BINS = 2 # the outer anchor, this many line points beyond the inner one
  ANCHOR_M = 25.0
  DETOUR_FACTOR = 1.5
  DETOUR_SLACK_M = 50.0
  OFFSET_SHARE = 0.35
  OFFSET_MIN_M = 30.0
  SEARCH_RADIUS_M = 30
  GPS_ACCURACY_M = 10.0
  BREAKAGE_M = 2000 # one path across the gap, however long it is

  # line and every stretch ([from_m, to_m] along the returned line): gaps
  # left as they were, filled ones routed
  Result = Struct.new(:line, :gaps, :filled, keyword_init: true)

  def initialize(user, client: nil, step: Corridors::Builder::BIN)
    @user = user
    @client = client
    @step = step
  end

  # gaps: [[first, last], ...] indices of `line` with few real fixes, inner
  # ones only (the ends of a route are always supported); frame: the one the
  # line's local metres are in (each route has its own)
  def call(mode, line, gaps, frame:)
    @frame = frame
    out = []
    marks = []
    cursor = 0
    gaps.each do |first, last|
      a = first - 1
      b = last + 1
      out.concat(line[cursor..a])
      path = (route(line, a, b) if MODES.include?(mode))
      if path
        marks << [:filled, out.size - 1, out.size + path.size] # line[a] .. line[b]
        out.concat(path)
      else
        marks << [:gap, out.size, out.size + last - first]
        out.concat(line[first..last])
      end
      cursor = b
    end
    out.concat(line[cursor..])
    s = G.lengths(out)
    stretches = ->(kind) { marks.select { |k, *| k == kind }.map { |_, i, j| [s[i].round, s[j].round] } }
    Result.new(line: out, gaps: stretches.call(:gap), filled: stretches.call(:filled))
  end

  private

  # The routed path strictly between line[a] and line[b] (resampled every
  # step), or nil.
  def route(line, a, b)
    return nil unless client

    anchors = [[a - OUTER_BINS, 0].max, a, b, [b + OUTER_BINS, line.size - 1].min].uniq
    path = matched_path(anchors.map { |i| line[i] }, anchors.index(a), anchors.index(b))
    return nil unless path

    median = line[a..b]
    gap_m = G.length(median)
    offset = G.project(median, G.lengths(median), path, back: Float::INFINITY, forward: Float::INFINITY).map { |_, o| o.abs }.max
    if G.length(path) > (DETOUR_FACTOR * gap_m) + DETOUR_SLACK_M || offset > [OFFSET_SHARE * gap_m, OFFSET_MIN_M].max
      return kept("gap #{gap_m.round} m: routed #{G.length(path).round} m, up to #{offset.round} m off (a detour)")
    end
    resampled = G.resample(path, @step)
    resampled.size > 2 ? resampled[1...-1] : nil # the ends are the matched anchors: line[a] and line[b] stay
  end

  # => [[x, y], ...] from the inner anchor before the gap to the one after it
  def matched_path(points, ia, ib)
    shape = points.map { |x, y| @frame.lonlat(x, y) }.map { |lon, lat| { lat: lat.round(7), lon: lon.round(7) } }
    body = { shape:, mode: 'pedestrian', shape_match: 'map_snap', format: 'polyline6', include_directions: false,
             search_radius: SEARCH_RADIUS_M, gps_accuracy: GPS_ACCURACY_M, breakage_distance: BREAKAGE_M }
    data = @client.map_match(body)['data']
    legs = data.is_a?(Hash) ? Array(data['legs']) : []
    matched = data.is_a?(Hash) ? Array(data['matched_points']) : []
    return kept("#{legs.size} paths for #{matched.size}/#{points.size} points") unless legs.size == 1 && matched.size == points.size
    return kept('an anchor next to the gap is unmatched') unless [ia, ib].all? { |i| Gtfs::Walk::BaseClient.usable_match?(matched[i]) }

    ends = [ia, ib].map { |i| @frame.xy(matched[i]['lon'], matched[i]['lat']) }
    return kept("an anchor matched over #{ANCHOR_M.round} m away") unless [ia, ib].each_with_index.all? { |i, k| G.dist(points[i], ends[k]) <= ANCHOR_M }

    path = Gtfs::Walk::BaseClient.decode_polyline6(legs.first['shape'].to_s).map { |lon, lat| @frame.xy(lon, lat) }
    return kept('empty path') if path.size < 2

    s = G.lengths(path)
    from, to = G.project(path, s, ends, back: Float::INFINITY, forward: Float::INFINITY).map(&:first)
    to > from ? G.slice(path, s, from, to) : kept('path runs backwards')
  rescue Gtfs::Walk::BaseClient::Unavailable => e
    log(:warn, "gap filling off for this build: #{e.message}")
    @client = false
    nil
  rescue Gtfs::Walk::BaseClient::Error => e
    kept(e.message)
  end

  def kept(why)
    log(:info, "gap not routed, median kept: #{why}")
    nil
  end

  def client
    return @client unless @client.nil?

    @client = usable? && Gtfs::Walk::BaseClient.build.tap(&:healthy!)
  rescue Gtfs::Walk::BaseClient::Unavailable => e
    log(:warn, "gap filling off for this build: #{e.message}")
    @client = false
  end

  def usable?
    return false unless Corridors::Config.fill_gaps?

    c = Gtfs::Walk::Config
    reason = if c.api != 'atlas' then 'GTFS_WALK_VALHALLA_API is not atlas'
             elsif (problem = c.url_problem) then problem
             elsif !c.exclude_list_set? then 'GTFS_WALK_SNAP_EXCLUDE_EMAILS is not set or empty'
             elsif c.excluded?(@user) then 'user excluded from walk snapping'
             end
    log(:info, "gaps not filled: #{reason}") if reason
    reason.nil?
  end

  def log(level, message) = Rails.logger.public_send(level, "[corridors] user #{@user.id}: #{message}")
end
