# frozen_string_literal: true

# A walking leg for the API and the map layer (docs/gtfs-walk.md).
#
# #call: the leg's properties (flat, so MapLibre can style on them).
# #features: one GeoJSON feature per drawn part, in time order: snapped
# (`valhalla`) and recorded (`raw`) parts as LineStrings, a stationary cloud
# as one Point (its centre). `gap` parts are not drawn, so a jump in the
# recording never becomes a straight line.
class Api::TransitWalkLegSerializer
  DIGITS = Gtfs::WalkLegQuery::COORD_DIGITS

  def initialize(leg)
    @leg = leg
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
    end
  end

  private

  def parts
    @parts ||= Array(@leg.parts).select { |p| p.is_a?(Hash) && p['coords'].is_a?(Array) && p['coords'].any? }
  end

  def centre(coords)
    [(coords.sum(&:first) / coords.size).round(DIGITS), (coords.sum(&:last) / coords.size).round(DIGITS)]
  end
end
