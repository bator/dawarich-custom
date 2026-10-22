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
    legs = query.map_legs
    fixes = end_fixes(legs)
    features = legs.flat_map do |leg|
      ends = [fixes[leg.point_ids&.first], fixes[leg.point_ids&.last]]
      Api::TransitWalkLegSerializer.new(leg, ends:).features
    end
    render json: { type: 'FeatureCollection', features: }
  end

  private

  # point id => [lon, lat] of every leg's first and last fix (point_ids are
  # in time order), for the joints to the raw track line; one query
  def end_fixes(legs)
    ids = legs.flat_map { |leg| [leg.point_ids&.first, leg.point_ids&.last] }.compact.uniq
    return {} if ids.empty?

    Point.where(id: ids).pluck(:id, Arel.sql('ST_X(lonlat::geometry)'), Arel.sql('ST_Y(lonlat::geometry)'))
         .to_h { |id, lon, lat| [id, [lon, lat]] }
  end

  def query_keys
    %i[start_at end_at page per_page]
  end
end
