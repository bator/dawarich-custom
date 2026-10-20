# frozen_string_literal: true

# Frequent routes of the signed-in user (docs/corridors.md), read only.
class Api::V1::Transit::CorridorsController < Api::V1::Transit::BaseController
  # GET /api/v1/transit/corridors : GeoJSON for the map layer (empty while CORRIDORS_ENABLED is off),
  # one feature per piece of a route: `part` gps (the median) or filled (routed through a gap)
  def index
    corridors = Corridors::Config.enabled? ? TrackCorridor.where(user_id: current_api_user.id).order(trips: :desc) : []
    features = corridors.flat_map do |c|
      properties = { id: c.id, mode: c.mode, trips: c.trips, length_m: c.length_m.round,
                     spread_p50: c.spread_p50, spread_p90: c.spread_p90, gaps: c.gaps, filled: c.filled,
                     gaps_m: c.stretch_m(c.gaps), filled_m: c.stretch_m(c.filled) }
      c.parts.map do |coords, routed|
        {
          type: 'Feature',
          geometry: { type: 'LineString', coordinates: coords.map { |x, y| [x.round(6), y.round(6)] } },
          properties: properties.merge(part: routed ? 'filled' : 'gps')
        }
      end
    end
    render json: { type: 'FeatureCollection', features: }
  end
end
