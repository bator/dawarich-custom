# frozen_string_literal: true

# Phase 3 transit API (spec 11). Errors are always JSON: 401 (ApiController),
# 404 for a missing or foreign segment, 422 for invalid parameters.
class Api::V1::Transit::BaseController < ApiController
  rescue_from Gtfs::SegmentQuery::InvalidParams, Gtfs::SegmentReview::Invalid, with: :unprocessable

  private

  def unprocessable(error)
    render json: { error: 'invalid_parameter', message: error.message }, status: :unprocessable_content
  end

  def segment_not_found
    # Review item A2: an auto ride can get a new id when its day is matched again
    render json: { error: 'not_found', reload: true,
                   message: 'Transit segment not found; it may have been re-matched. Reload the list.' },
           status: :not_found
  end
end
