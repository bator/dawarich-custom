# frozen_string_literal: true

# POST /api/v1/transit/rematch { start_at: "2026-10-01", end_at: "2026-10-07" }
# Queues one matching job per day (asynchronous) and returns their job ids.
# Rate limited per user (spec 15), also on self-hosted instances where
# Rack::Attack is off.
class Api::V1::Transit::RematchesController < Api::V1::Transit::BaseController
  MAX_DAYS = 31
  RATE_LIMIT = 5

  before_action :require_write_api!

  rate_limit to: RATE_LIMIT, within: 1.hour, by: -> { "transit-rematch:#{current_api_user&.id}" },
             with: :render_rate_limited

  def create
    unless Gtfs::UserSettings.new(current_api_user).enabled?
      return render json: { error: 'gtfs_disabled', message: 'Transit detection is not enabled for this user.' },
                    status: :unprocessable_content
    end

    dates = requested_dates
    jobs = []
    queued = Gtfs::MatchUserDaysJob.enqueue_days(current_api_user.id, dates, jobs:)
    render json: { status: 'queued', dates: queued.map(&:iso8601), already_queued: (dates.to_a - queued).map(&:iso8601),
                   job_ids: jobs.map(&:job_id) }, status: :accepted
  end

  private

  def render_rate_limited
    render json: { error: 'rate_limited', message: 'Too many rematch requests, try again later.' },
           status: :too_many_requests
  end

  def requested_dates
    from = parse_date(:start_at)
    to = parse_date(:end_at)
    today = Gtfs::MatchDay.today_for(current_api_user)
    raise Gtfs::SegmentQuery::InvalidParams, 'end_at must not be before start_at' if to < from
    raise Gtfs::SegmentQuery::InvalidParams, "at most #{MAX_DAYS} days per request" if (to - from).to_i >= MAX_DAYS
    raise Gtfs::SegmentQuery::InvalidParams, 'days must not be in the future' if to > today

    from..to
  end

  def parse_date(key)
    Date.iso8601(params.require(key).to_s)
  rescue ActionController::ParameterMissing, Date::Error
    raise Gtfs::SegmentQuery::InvalidParams, "#{key} must be a date (YYYY-MM-DD)"
  end
end
