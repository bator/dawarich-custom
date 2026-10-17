# frozen_string_literal: true

# Raw Valhalla backend: POST /trace_attributes (costing pedestrian,
# shape_match map_snap), health check GET /status. Runs split at unmatched
# points, at Valhalla's route discontinuity flags and where the answer
# contains independent paths without those flags (review N1: the next edge
# does not start where the previous one ended, or end_node.elapsed_time
# starts again from zero).
class Gtfs::Walk::ValhallaClient < Gtfs::Walk::BaseClient
  ATTRIBUTES = %w[
    shape edge.begin_shape_index edge.end_shape_index edge.length node.elapsed_time
    matched.point matched.type matched.edge_index matched.distance_from_trace_point
    matched.begin_route_discontinuity matched.end_route_discontinuity
  ].freeze

  # points: objects with lon, lat, ts, accuracy
  def trace_runs(points)
    raise ArgumentError, 'at least two points needed' if points.size < 2

    self.class.runs_from(post_json('/trace_attributes', request_body(points)), points.size)
  end

  def request_body(points)
    options = self.class.trace_options(points)
    turn_penalty = Gtfs::Walk::Config::TURN_PENALTY_FACTOR
    options[:turn_penalty_factor] = turn_penalty if turn_penalty.positive?
    {
      shape: points.map { |p| self.class.shape_point(p) },
      costing: 'pedestrian',
      shape_match: 'map_snap',
      trace_options: options,
      filters: { attributes: ATTRIBUTES, action: 'include' }
    }
  end

  # Splits the response into runs (see Gtfs::Walk::BaseClient).
  def self.runs_from(body, n_points)
    matched = body['matched_points']
    unless matched.is_a?(Array) && matched.size == n_points
      raise Unavailable, "matched_points size #{Array(matched).size} != #{n_points}"
    end

    shape = decode_polyline6(body['shape'].to_s)
    edges = Array(body['edges'])
    group(matched, edges).filter_map { |run| build_run(run, shape, edges) }
  end

  def self.group(matched, edges)
    runs = []
    current = nil
    matched.each_with_index do |m, i|
      usable = usable_match?(m) && m['edge_index'].is_a?(Integer) && edges[m['edge_index']]
      if !usable || (current && (m['begin_route_discontinuity'] ||
                                 path_break?(edges, current.last[1]['edge_index'], m['edge_index'])))
        runs << current if current
        current = nil
      end
      next unless usable

      current ||= []
      current << [i, m]
      if m['end_route_discontinuity']
        runs << current
        current = nil
      end
    end
    runs << current if current
    runs
  end

  # True when the edges from..to are not one continuous path (review N1/U1):
  # a shape segment between two edges that no edge range covers (the next
  # edge does not begin where the previous one ended) -- an exact signal,
  # independent of the segment's length, so a long bridge edge is never cut --
  # or a restarting end_node.elapsed_time.
  def self.path_break?(edges, from, to)
    return true if to < from

    ((from + 1)..to).any? do |k|
      before = edges[k - 1]
      edge = edges[k]
      edge['begin_shape_index'] != before['end_shape_index'] || elapsed_restart?(before, edge)
    end
  end

  def self.elapsed_restart?(before, edge)
    was = before.dig('end_node', 'elapsed_time')
    now = edge.dig('end_node', 'elapsed_time')
    was.is_a?(Numeric) && now.is_a?(Numeric) && now < was
  end

  def self.build_run(run, shape, edges)
    first_i, first_m = run.first
    last_i, last_m = run.last
    return nil if first_i == last_i

    from = edges[first_m['edge_index']]['begin_shape_index'].to_i
    to = edges[last_m['edge_index']]['end_shape_index'].to_i
    return nil if to <= from

    coords = trim(shape[from..to], [first_m['lon'], first_m['lat']], [last_m['lon'], last_m['lat']],
                  head_until: edges[first_m['edge_index']]['end_shape_index'].to_i - from,
                  tail_from: edges[last_m['edge_index']]['begin_shape_index'].to_i - from)
    return nil if coords.size < 2

    Run.new(first_index: first_i, last_index: last_i, coords:)
  end

  private

  # A Valhalla answers /status with its version and actions (review K2: the
  # old default URL was Apprise, which answers "OK").
  def check_health!
    status = get_json('/status')
    actions = Array(status['available_actions'])
    return if status['version'].is_a?(String) && actions.include?('trace_attributes')

    raise Unavailable, "#{@url}/status is not a Valhalla with trace_attributes"
  end

  # Valhalla answers a trace it cannot match with 400 and an error_code.
  def rejected?(code, parsed) = code == '400' && parsed.key?('error_code')

  def error_message(parsed) = "#{parsed['error_code']} #{parsed['error']}"
end
