# frozen_string_literal: true

# Snaps one walking leg onto footpaths with Valhalla and returns its drawable
# geometry as parts, in time order:
#
#   { source: 'valhalla', coords: [...] }   a matched run that passed Gtfs::Walk::Quality
#   { source: 'raw', coords: [...] }        recorded GPS: unmatched stretches, gaps
#                                           between runs, failed runs, Valhalla errors
#   { source: 'stationary', coords: [...] } a stationary cloud, as recorded
#   { source: 'gap', secs:, m: }             two consecutive recorded fixes farther
#                                           apart than RAW_MAX_SEGMENT_M (not drawn)
#
# Parts are separate lines. Nothing is ever joined with a long straight line
# (review M6): a raw part is the recorded polyline itself, cut where two fixes
# are more than RAW_MAX_SEGMENT_M apart, and a snapped part starts/ends at the
# matched position of its first/last recorded point.
#
# A trace the server rejects (BaseClient::Error) stays raw. When the server is
# unavailable or the day's time budget is used up, the breaker opens and no
# further request is sent (the caller then writes nothing, review M1).
class Gtfs::Walk::Snapper
  Result = Struct.new(:parts, :stats, keyword_init: true)

  def initialize(client:, logger: nil, breaker: Gtfs::Walk::Breaker.new)
    @client = client
    @logger = logger
    @breaker = breaker
  end

  def call(leg_points)
    @parts = []
    @stats = Hash.new(0)
    @stats['reasons'] = Hash.new(0)
    Gtfs::Walk::StationaryFilter.new(leg_points).call.each do |piece|
      if piece.stationary?
        @stats['stationary_clouds'] += 1
        @stats['stationary_points'] += piece.points.size
        add_part('stationary', piece.points)
      else
        snap_piece(piece.points)
      end
    end
    @stats['metrics'] = self.class.leg_metrics(leg_points, @parts)
    @stats['reasons'] = @stats['reasons'].to_h
    Result.new(parts: @parts, stats: @stats.to_h)
  end

  # Fidelity of the whole drawn leg against the recorded points.
  def self.leg_metrics(points, parts)
    raw_coords = points.map { |p| [p.lon.to_f, p.lat.to_f] }
    projector = Gtfs::Matching::Geo.projector(raw_coords.first[1])
    drawn = parts.select { |part| part[:coords] }
    lines = drawn.map { |part| Gtfs::Matching::Geo::Polyline.new(part[:coords], projector) }.select(&:usable?)
    distances = raw_coords.map do |lon, lat|
      x, y = projector.call(lon, lat)
      lines.map { |l| l.project(x, y)[1] }.min || 0.0
    end
    length = ->(list) { list.sum { |part| Gtfs::Walk::Quality.length(part[:coords]) } }
    raw_m = Gtfs::Walk::Quality.length(raw_coords)
    out_m = length.call(drawn)
    {
      'raw_m' => raw_m.round(1), 'drawn_m' => out_m.round(1),
      'snapped_m' => length.call(drawn.select { |part| part[:source] == 'valhalla' }).round(1),
      'ratio' => raw_m.positive? ? (out_m / raw_m).round(3) : nil,
      'median_m' => Gtfs::Walk::Quality.percentile(distances, 0.5).round(1),
      'p95_m' => Gtfs::Walk::Quality.percentile(distances, 0.95).round(1),
      'within_25_share' => within_share(distances),
      'points' => raw_coords.size
    }
  end

  def self.within_share(distances)
    return 0.0 if distances.empty?

    (distances.count { |d| d <= Gtfs::Walk::Config::WITHIN_M }.to_f / distances.size).round(3)
  end

  private

  def snap_piece(points)
    if points.size < Gtfs::Walk::Config::MIN_RUN_POINTS
      fallback(points, 'too_few_points')
      return
    end

    request = Gtfs::Walk::StationaryFilter.thin(points)
    index_of = {}.compare_by_identity
    points.each_with_index { |p, i| index_of[p] = i }
    accepted = []
    chunks(request).each do |chunk|
      runs = trace(chunk)
      next if runs.nil?

      runs.each do |run|
        from = index_of[chunk[run.first_index]]
        to = index_of[chunk[run.last_index]]
        accepted << [from, to, judge(points[from..to], run.coords)]
      end
    end
    compose(points, accepted)
  end

  def chunks(request)
    size = Gtfs::Walk::Config::MAX_REQUEST_POINTS
    return [request] if request.size <= size

    request.each_slice(size - 1).each_with_index.map do |slice, i|
      i.zero? ? slice : [request[(i * (size - 1)) - 1], *slice]
    end
  end

  # => runs, or nil (the chunk stays raw)
  def trace(chunk)
    if @breaker.open?
      @stats['valhalla_skipped'] += 1
      return nil
    end

    @stats['valhalla_requests'] += 1
    @client.trace_runs(chunk)
  rescue Gtfs::Walk::BaseClient::Unavailable => e
    @stats['valhalla_unavailable'] += 1
    @breaker.trip!('valhalla_unavailable') unless @breaker.open? # open? names a used-up budget
    @logger&.warn("[GTFS walk] map matching unavailable, no more requests for this day: #{e.message}")
    nil
  rescue Gtfs::Walk::BaseClient::Error => e
    @stats['valhalla_errors'] += 1
    @stats['reasons']['valhalla_error'] += 1
    @logger&.info("[GTFS walk] trace rejected, kept as recorded: #{e.message}")
    nil
  end

  # => coords when the run passes the quality gates, else nil (raw fallback)
  def judge(raw, coords)
    @stats['runs'] += 1
    quality = Gtfs::Walk::Quality.check(raw, coords)
    if quality.ok
      @stats['runs_snapped'] += 1
      coords
    else
      @stats['runs_rejected'] += 1
      @stats['reasons'][quality.reason.split.first] += 1
      nil
    end
  end

  # Raw parts fill everything between accepted runs (inclusive of the
  # recorded boundary points, so the recorded line is complete).
  def compose(points, accepted)
    cursor = 0
    accepted.select { |_, _, coords| coords }.sort_by(&:first).each do |from, to, coords|
      next if from < cursor # overlapping chunk edge: keep the earlier run

      add_raw_gap(points[cursor..from]) if from > cursor
      add_snapped(coords)
      cursor = to
    end
    add_raw_gap(points[cursor..]) if cursor < points.size - 1
  end

  # The snapped line, cut (gap marker, not drawn) at a straight segment longer
  # than SNAP_MAX_SEGMENT_M (last-resort net, review N1/U1).
  def add_snapped(coords)
    max = Gtfs::Walk::Config::SNAP_MAX_SEGMENT_M
    length = ->(a, b) { Gtfs::Matching::Geo.haversine(a[0], a[1], b[0], b[1]) }
    pieces = coords.slice_when { |a, b| length.call(a, b) > max }.to_a
    pieces.each_with_index do |piece, i|
      if i.positive?
        @stats['snap_cuts'] += 1
        @parts << { source: 'gap', m: length.call(pieces[i - 1].last, piece.first).round }
      end
      @parts << { source: 'valhalla', coords: piece } if piece.size >= 2
    end
  end

  def add_raw_gap(points)
    return if points.size < 2

    @stats['raw_parts'] += 1
    add_part('raw', points)
  end

  def fallback(points, reason)
    @stats['reasons'][reason] += 1
    add_raw_gap(points)
  end

  # Recorded points as one or more lines, cut at every jump longer than
  # RAW_MAX_SEGMENT_M (a `gap` marker records it without drawing it).
  def add_part(source, points)
    max = Gtfs::Walk::Config::RAW_MAX_SEGMENT_M
    pieces = points.slice_when do |a, b|
      Gtfs::Matching::Geo.haversine(a.lon, a.lat, b.lon, b.lat) > max
    end.to_a
    pieces.each_with_index do |piece, i|
      if i.positive?
        a = pieces[i - 1].last
        b = piece.first
        @stats['gaps'] += 1
        @parts << { source: 'gap', secs: b.ts - a.ts,
                    m: Gtfs::Matching::Geo.haversine(a.lon, a.lat, b.lon, b.lat).round }
      end
      coords = piece.map { |p| [p.lon.to_f.round(7), p.lat.to_f.round(7)] }
      @parts << { source:, coords: } if coords.size >= 2
    end
  end
end
