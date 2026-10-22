# frozen_string_literal: true

# A walking leg for the API and the map layer (docs/gtfs-walk.md).
#
# #call: the leg's properties (flat, so MapLibre can style on them).
# #features: one GeoJSON feature per drawn part, in time order: snapped
# (`valhalla`) and recorded (`raw`) parts as LineStrings, a stationary cloud
# as one Point (its centre), and `joint` LineStrings that join them (see
# #joints).
class Api::TransitWalkLegSerializer
  DIGITS = Gtfs::WalkLegQuery::COORD_DIGITS

  # ends: the leg's first and last recorded fix ([lon, lat] each), where the
  # map's raw track line meets the walk
  def initialize(leg, ends: nil)
    @leg = leg
    @ends = ends
  end

  def call
    stats = @leg.stats || {}
    metrics = stats['metrics'] || {}
    {
      id: @leg.id, started_at: @leg.started_at, ended_at: @leg.ended_at, source: @leg.source,
      distance_m: @leg.distance_m&.round, raw_distance_m: @leg.raw_distance_m&.round,
      point_count: @leg.point_count, ride_ids: @leg.ride_ids,
      runs: stats['runs'].to_i, runs_snapped: stats['runs_snapped'].to_i, runs_rejected: stats['runs_rejected'].to_i,
      raw_parts: stats['raw_parts'].to_i, gaps: stats['gaps'].to_i,
      ratio: metrics['ratio'], median_m: metrics['median_m'], p95_m: metrics['p95_m'],
      within_25_share: metrics['within_25_share'],
      part_sources: parts.map { |p| p['source'] }
    }
  end

  def features
    props = call
    parts.each_with_index.filter_map do |part, index|
      coords = part['coords'].map { |lon, lat| [lon.to_f.round(DIGITS), lat.to_f.round(DIGITS)] }
      geometry = if part['source'] == 'stationary'
                   { type: 'Point', coordinates: centre(coords) }
                 elsif coords.size >= 2
                   { type: 'LineString', coordinates: coords }
                 end
      next unless geometry

      { type: 'Feature', geometry:, properties: props.merge(part_source: part['source'], part_index: index) }
    end + joints(props)
  end

  private

  # The parts do not touch: a snapped part ends at its matched position, the
  # next part (or the raw track line around the leg) starts at the recorded
  # fix, 20-40 m away (2026-10-22), and a GPS gap between two parts is not a
  # part at all. Bator: where there is no snapped way, the raw GPS connects.
  # So a straight joint goes from the end of each part to the start of the
  # next one (a stationary cloud by its first and last fix, not its centre),
  # and from the leg's first fix to a snapped first part and from a snapped
  # last part to its last fix.
  def joints(props)
    stops = []
    stops << [@ends.first, @ends.first] if @ends&.first && parts.first&.dig('source') == 'valhalla'
    parts.each { |part| stops << [part['coords'].first, part['coords'].last] }
    stops << [@ends.last, @ends.last] if @ends&.last && parts.last&.dig('source') == 'valhalla'
    stops.each_cons(2).each_with_index.filter_map do |(before, after), index|
      from = rounded(before.last)
      to = rounded(after.first)
      next if from == to

      { type: 'Feature', geometry: { type: 'LineString', coordinates: [from, to] },
        properties: props.merge(part_source: 'joint', part_index: index) }
    end
  end

  def rounded((lon, lat)) = [lon.to_f.round(DIGITS), lat.to_f.round(DIGITS)]

  def parts
    @parts ||= Array(@leg.parts).select { |p| p.is_a?(Hash) && p['coords'].is_a?(Array) && p['coords'].any? }
  end

  def centre(coords)
    [(coords.sum(&:first) / coords.size).round(DIGITS), (coords.sum(&:last) / coords.size).round(DIGITS)]
  end
end
