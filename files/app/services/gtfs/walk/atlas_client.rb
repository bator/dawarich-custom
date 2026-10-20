# frozen_string_literal: true

# Dawarich Atlas backend (preferred): POST /api/v1/map-match (mode
# pedestrian, shape_match map_snap, format polyline6), health check
# GET /api/v1/coverage (map_matching must be available).
#
# Atlas returns one encoded polyline per continuous matched path (`legs`,
# split where Valhalla starts a new path) and one correlation per input point
# (`matched_points` with the matched position), but no edge ranges or
# discontinuity flags. A matched point belongs to the first path, from the
# previous point's path on, that passes within ON_PATH_M of its matched
# position; runs split where the path changes or a point is unmatched.
#
# A path is not always one walk (Valhalla 3.5.1 in Atlas 0.6.1, recorded in
# spec/fixtures/files/gtfs/walk/atlas_*.json):
# - a later path can begin at the previous path's end with a straight jump to
#   its own first matched point (1357 m across the Danube), and
# - two walks far apart can come back as one path, routed in between,
#   although breakage_distance asked Valhalla to break there.
# So a run is cut to the stretch between its own first and last matched
# point (never across a path boundary), and runs also split between two
# consecutive matched points that are farther apart than MAX_POINT_GAP_M (the
# breakage_distance the raw Valhalla client relies on, and the leg
# extractor's gap) or whose stretch of path is no plausible walk between them
# (longer than DETOUR_FACTOR x the straight distance + DETOUR_SLACK_M).
class Gtfs::Walk::AtlasClient < Gtfs::Walk::BaseClient
  ON_PATH_M = 2.0
  DETOUR_FACTOR = 3.0
  DETOUR_SLACK_M = 100.0

  def trace_runs(points)
    raise ArgumentError, 'at least two points needed' if points.size < 2

    self.class.runs_from(post_json('/api/v1/map-match', request_body(points)), points.size)
  end

  # The parsed answer to a request body of the caller's own (the frequent
  # routes' gap filling, Corridors::GapFiller), same errors as #trace_runs.
  def map_match(body) = post_json('/api/v1/map-match', body)

  def request_body(points)
    {
      shape: points.map { |p| self.class.shape_point(p) },
      mode: 'pedestrian',
      shape_match: 'map_snap',
      format: 'polyline6',
      include_directions: false,
      **self.class.trace_options(points)
    }
  end

  def self.runs_from(body, n_points)
    data = body['data']
    raise Unavailable, 'map-match answer without data' unless data.is_a?(Hash)

    matched = data['matched_points']
    unless matched.is_a?(Array) && matched.size == n_points
      raise Unavailable, "matched_points size #{Array(matched).size} != #{n_points}"
    end

    paths = Array(data['legs']).map { |leg| decode_polyline6(leg.is_a?(Hash) ? leg['shape'].to_s : '') }
    lines = path_lines(paths)
    group(matched, paths, lines).filter_map { |path_index, run| build_run(run, lines[path_index]) }
  end

  # => [[path_index, [[input_index, matched_point, along_m], ...]], ...]
  def self.group(matched, paths, lines = path_lines(paths))
    runs = []
    current = nil
    path = 0
    matched.each_with_index do |m, i|
      found = usable_match?(m) ? path_of(m, lines, path) : nil
      along = nil
      if found
        previous = current && current[0] == found ? current[1].last : nil
        along = along_on(lines[found], m, previous ? previous[2] : 0.0)
        if previous && implausible_step?(previous[1], m, along - previous[2])
          runs << current
          current = nil
        end
      end
      if current && found != current[0]
        runs << current
        current = nil
      end
      next if found.nil?

      path = found
      current ||= [found, []]
      current[1] << [i, m, along]
    end
    runs << current if current
    runs
  end

  def self.path_lines(paths)
    paths.map do |coords|
      next nil if coords.size < 2

      projector = Gtfs::Matching::Geo.projector(coords.first[1])
      line = Gtfs::Matching::Geo::Polyline.new(coords, projector)
      line.usable? ? [line, projector] : nil
    end
  end

  def self.path_of(matched, lines, from)
    (from...lines.size).find do |i|
      next false unless lines[i]

      line, projector = lines[i]
      line.project(*projector.call(matched['lon'], matched['lat']))[1] <= ON_PATH_M
    end
  end

  # Metres along the path of the matched position: the first place at or
  # after `from` that passes within ON_PATH_M (a path can come back to the
  # same spot later, e.g. a lead-in to the next walk), else the closest one.
  def self.along_on(entry, matched, from)
    line, projector = entry
    point = projector.call(matched['lon'], matched['lat'])
    first_near(line, point, from) || line.project(*point, from:)[0]
  end

  def self.first_near(line, point, from)
    start = [(line.cumulative.bsearch_index { |c| c > from } || line.cumulative.size) - 1, 0].max
    (start...(line.xs.size - 1)).each do |i|
      along, dist = on_segment(line, i, point)
      along = [along, from].max
      return along if dist <= ON_PATH_M
    end
    nil
  end

  # => [along_m, distance_m] of the closest point of segment `index`
  def self.on_segment(line, index, point)
    px, py = point
    ax = line.xs[index]
    ay = line.ys[index]
    dx = line.xs[index + 1] - ax
    dy = line.ys[index + 1] - ay
    len2 = (dx * dx) + (dy * dy)
    t = len2.zero? ? 0.0 : ((((px - ax) * dx) + ((py - ay) * dy)) / len2).clamp(0.0, 1.0)
    along = line.cumulative[index] + (t * (line.cumulative[index + 1] - line.cumulative[index]))
    [along, Math.hypot(px - (ax + (t * dx)), py - (ay + (t * dy)))]
  end

  def self.implausible_step?(before, after, walked)
    straight = Gtfs::Matching::Geo.haversine(before['lon'], before['lat'], after['lon'], after['lat'])
    return true if straight > Gtfs::Walk::Config::MAX_POINT_GAP_M

    walked > [straight * DETOUR_FACTOR, straight + DETOUR_SLACK_M].max
  end

  # The path from the run's first to its last matched point only.
  def self.build_run(run, entry)
    first_i, _, from = run.first
    last_i, _, to = run.last
    return nil if first_i == last_i || entry.nil? || to <= from

    line, projector = entry
    coords = cut(line, projector, from, to)
    return nil if coords.size < 2

    Run.new(first_index: first_i, last_index: last_i, coords:)
  end

  private

  def check_health!
    body = get_json('/api/v1/coverage')
    matching = body.dig('data', 'capabilities', 'map_matching')
    raise Unavailable, "#{@url}/api/v1/coverage has no map_matching capability" unless matching.is_a?(Hash)
    return if matching['available'] == true

    raise Unavailable, "Atlas map matching is not ready (status #{matching['status'].inspect})"
  end

  # Atlas answers an unmatchable or invalid trace with 422 (400: no shape).
  def rejected?(code, parsed) = %w[400 422].include?(code) && parsed['error'].is_a?(Hash)

  def error_message(parsed)
    error = parsed['error']
    error.is_a?(Hash) ? "#{error['code']} #{error['message']}" : parsed.to_s[0, 80]
  end
end
