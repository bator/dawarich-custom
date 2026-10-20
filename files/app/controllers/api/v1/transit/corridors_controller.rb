# frozen_string_literal: true

# Frequent routes of the signed-in user (docs/corridors.md), read only.
class Api::V1::Transit::CorridorsController < Api::V1::Transit::BaseController
  # GET /api/v1/transit/corridors : GeoJSON for the map layer (empty while CORRIDORS_ENABLED is off)
  def index
    corridors = Corridors::Config.enabled? ? TrackCorridor.where(user_id: current_api_user.id).order(trips: :desc) : []
    features = corridors.map do |c|
      {
        type: 'Feature',
        geometry: { type: 'LineString', coordinates: c.path.points.map { |p| [p.x.round(6), p.y.round(6)] } },
        properties: { id: c.id, mode: c.mode, trips: c.trips, length_m: c.length_m.round,
                      spread_p50: c.spread_p50, spread_p90: c.spread_p90, gaps: c.gaps }
      }
    end
    render json: { type: 'FeatureCollection', features: }
  end
end
