# frozen_string_literal: true

# GET /api/v1/transit/stats?year=2026&month=10 (month optional)
class Api::V1::Transit::StatsController < Api::V1::Transit::BaseController
  def index
    year = param_int(:year, 1970..2100)
    month = param_int(:month, 1..12, required: false)
    render json: { data: Gtfs::SegmentStats.new(current_api_user, year: year, month: month).call }
  end

  private

  def param_int(key, range, required: true)
    value = params[key].presence
    return nil if value.nil? && !required

    number = Integer(value.to_s, exception: false)
    unless number && range.cover?(number)
      raise Gtfs::SegmentQuery::InvalidParams, "#{key} must be an integer in #{range}"
    end

    number
  end
end
