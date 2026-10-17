# frozen_string_literal: true

# Walking legs next to the transit rides (docs/gtfs-walk.md), read only.
# Same authentication, parameters and visibility rules as the segments.
class Api::V1::Transit::WalkLegsController < Api::V1::Transit::BaseController
  # GET /api/v1/transit/walk_legs?start_at=&end_at=&page=&per_page=
  # meta.total only with start_at (null otherwise), meta.has_more always.
  def index
    query = Gtfs::WalkLegQuery.new(current_api_user, params.permit(*query_keys))
    legs, more = query.page_with_more

    render json: {
      data: legs.map { |leg| Api::TransitWalkLegSerializer.new(leg).call },
      meta: { page: query.page, per_page: query.per_page, has_more: more, total: query.total }
    }
  end

  # GET /api/v1/transit/walk_legs/map?start_at=&end_at= : GeoJSON for the map layer
  def map
    query = Gtfs::WalkLegQuery.new(current_api_user, params.permit(*query_keys))
    features = query.map_legs.flat_map { |leg| Api::TransitWalkLegSerializer.new(leg).features }
    render json: { type: 'FeatureCollection', features: }
  end

  private

  def query_keys
    %i[start_at end_at page per_page]
  end
end
