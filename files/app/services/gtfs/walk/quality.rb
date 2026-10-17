# frozen_string_literal: true

# Quality gates for one snapped walking run, the same checks the OSRM car snap
# applies (length ratio, deviation from the recorded trace, distance of the
# recorded points to the new line):
#
# - length ratio snapped / recorded within [MIN, MAX] (dense or sparse trace,
#   +/- RATIO_MARGIN_M): too short = Valhalla cut a corner or lost part of the
#   walk, too long = a detour the walker did not take;
# - median and p95 distance of the recorded points to the line
#   (MAX_MEDIAN_M, MAX_P95_M);
# - deviation: share of the line farther than STRAY_FAR_M from the recorded
#   trace on both ends of a vertex pair (MAX_STRAY_FRACTION).
class Gtfs::Walk::Quality
  Result = Struct.new(:ok, :reason, :metrics, keyword_init: true)

  # raw: points (lon, lat); coords: [[lon, lat], ...]
  def self.check(raw, coords)
    c = Gtfs::Walk::Config
    m = metrics(raw, coords)
    return Result.new(ok: false, reason: 'degenerate', metrics: m) if m[:raw_m] <= 0 || m[:snapped_m] <= 0

    reason = failure(m, c)
    Result.new(ok: reason.nil?, reason: reason || 'ok', metrics: m)
  end

  def self.failure(met, cfg)
    min_ratio, max_ratio =
      met[:dense] ? [cfg::MIN_RATIO_DENSE, cfg::MAX_RATIO_DENSE] : [cfg::MIN_RATIO_SPARSE, cfg::MAX_RATIO_SPARSE]

    if met[:snapped_m] < (min_ratio * met[:raw_m]) - cfg::RATIO_MARGIN_M
      format('too_short ratio=%.2f', met[:ratio])
    elsif met[:snapped_m] > (max_ratio * met[:raw_m]) + cfg::RATIO_MARGIN_M
      format('detour ratio=%.2f', met[:ratio])
    elsif met[:median_m] > cfg::MAX_MEDIAN_M then format('median=%.0fm', met[:median_m])
    elsif met[:p95_m] > cfg::MAX_P95_M then format('p95=%.0fm', met[:p95_m])
    elsif met[:stray] > cfg::MAX_STRAY_FRACTION then format('stray=%.2f', met[:stray])
    end
  end

  def self.metrics(raw, coords)
    raw_coords = raw.map { |p| [p.lon.to_f, p.lat.to_f] }
    projector = Gtfs::Matching::Geo.projector(raw_coords.first[1])
    raw_m = length(raw_coords)
    snapped_m = length(coords)
    distances = distances_to(raw_coords, coords, projector)
    {
      raw_m: raw_m.round(1), snapped_m: snapped_m.round(1),
      ratio: raw_m.positive? ? (snapped_m / raw_m).round(3) : nil,
      median_m: percentile(distances, 0.5).round(1), p95_m: percentile(distances, 0.95).round(1),
      within_25_share: Gtfs::Walk::Snapper.within_share(distances),
      stray: stray_fraction(raw_coords, coords, projector).round(3),
      dense: median_spacing(raw_coords) <= Gtfs::Walk::Config::DENSE_SPACING_M,
      points: raw_coords.size
    }
  end

  def self.distances_to(points, coords, projector)
    line = Gtfs::Matching::Geo::Polyline.new(coords, projector)
    return points.map { 0.0 } unless line.usable?

    points.map do |lon, lat|
      x, y = projector.call(lon, lat)
      line.project(x, y)[1]
    end
  end

  def self.stray_fraction(raw_coords, coords, projector)
    trace = Gtfs::Matching::Geo::Polyline.new(raw_coords, projector)
    return 0.0 unless trace.usable?

    far = ->(lon, lat) { trace.project(*projector.call(lon, lat))[1] > Gtfs::Walk::Config::STRAY_FAR_M }
    total = 0.0
    off = 0.0
    prev_far = far.call(*coords.first)
    coords.each_cons(2) do |a, b|
      seg = Gtfs::Matching::Geo.haversine(a[0], a[1], b[0], b[1])
      total += seg
      now_far = far.call(*b)
      off += seg if prev_far && now_far
      prev_far = now_far
    end
    total.positive? ? off / total : 0.0
  end

  def self.length(coords)
    coords.each_cons(2).sum { |a, b| Gtfs::Matching::Geo.haversine(a[0], a[1], b[0], b[1]) }
  end

  def self.median_spacing(coords)
    gaps = coords.each_cons(2).map { |a, b| Gtfs::Matching::Geo.haversine(a[0], a[1], b[0], b[1]) }
    percentile(gaps, 0.5)
  end

  def self.percentile(values, quantile)
    return 0.0 if values.empty?

    sorted = values.sort
    pos = (sorted.size - 1) * quantile
    lo = sorted[pos.floor]
    hi = sorted[pos.ceil]
    lo + ((hi - lo) * (pos - pos.floor))
  end
end
