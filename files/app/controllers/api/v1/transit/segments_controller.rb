# frozen_string_literal: true

class Api::V1::Transit::SegmentsController < Api::V1::Transit::BaseController
  before_action :require_write_api!, only: :update
  rescue_from Gtfs::SegmentReview::NotFound, with: :segment_not_found

  # GET /api/v1/transit/segments?start_at=&end_at=&min_confidence=&status=&page=&per_page=
  def index
    query = Gtfs::SegmentQuery.new(current_api_user, params.permit(*query_keys))
    segments = query.paginated.to_a
    colors = Api::TransitSegmentSerializer.colors_for(segments)

    render json: {
      data: segments.map { |s| Api::TransitSegmentSerializer.new(s, colors:).call },
      meta: { page: query.page, per_page: query.per_page, total: query.total }
    }
  end

  # GET /api/v1/transit/segments/map?start_at=&end_at= : GeoJSON for the map layer
  def map
    query = Gtfs::SegmentQuery.new(current_api_user, params.permit(*query_keys))
    segments = query.scope.limit(Gtfs::SegmentQuery::MAX_MAP_SEGMENTS).to_a
    colors = Api::TransitSegmentSerializer.colors_for(segments)
    geometries = query.geometries(segments.map(&:id))

    features = segments.filter_map do |segment|
      geometry = geometries[segment.id]
      next unless geometry

      { type: 'Feature', geometry:, properties: Api::TransitSegmentSerializer.new(segment, colors:).call }
    end
    render json: { type: 'FeatureCollection', features: }
  end

  # GET /api/v1/transit/segments/:id
  def show
    segment = review.find(params[:id])
    colors = Api::TransitSegmentSerializer.colors_for([segment])
    render json: { data: Api::TransitSegmentSerializer.new(segment, colors:, detail: true).call }
  end

  # PATCH /api/v1/transit/segments/:id  { status: confirmed|rejected|auto }
  #                                     or { trip_gtfs_id:, feed_id: } (pick an alternative)
  def update
    segment = if params[:trip_gtfs_id].present?
                review.call(params[:id], 'choose', trip_gtfs_id: params[:trip_gtfs_id], feed_id: params[:feed_id])
              else
                review.call(params[:id], action_for(params[:status]))
              end
    colors = Api::TransitSegmentSerializer.colors_for([segment])
    render json: { data: Api::TransitSegmentSerializer.new(segment, colors:, detail: true).call }
  end

  private

  def query_keys
    %i[start_at end_at min_confidence status page per_page]
  end

  def review
    @review ||= Gtfs::SegmentReview.new(current_api_user, source: 'api')
  end

  def action_for(status)
    Gtfs::SegmentReview::STATUS_FOR.key(status.to_s.to_sym) ||
      raise(Gtfs::SegmentReview::Invalid, 'status must be confirmed, rejected or auto')
  end
end
