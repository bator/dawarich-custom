# frozen_string_literal: true

# Spec 12.3: the detected rides as a day-by-day timeline under a summary
# strip; each row opens to confirm / reject / undo and "another trip". All
# changes go through Gtfs::SegmentReview. A ride that was matched again
# meanwhile (review A2) gives a notice and a reloaded list.
class TransitSegmentsController < ApplicationController
  PERIODS = [7, 14, 30, 90, 365].freeze
  PER_PAGE = 50

  before_action :authenticate_user!

  def index
    @enabled = Gtfs::UserSettings.new(current_user).enabled?
    @days = PERIODS.include?(params[:days].to_i) ? params[:days].to_i : 14
    @only_uncertain = params[:uncertain] == '1'
    @page = [params[:page].to_i, 1].max
    @zone = ActiveSupport::TimeZone[current_user.timezone_iana] || Time.zone
    # One load for the summary strip and the list. TransitSegment#uncertain?
    # is computed in Ruby (thresholds and debug flags), so the "only
    # uncertain" filter and the review count need the rows anyway.
    all = Gtfs::SegmentQuery.new(current_user, start_at: @days.days.ago.to_i).scope.to_a
    @summary = summary(all)
    listed = @only_uncertain ? all.select(&:uncertain?) : all
    @total = listed.size
    @segments = listed.slice((@page - 1) * PER_PAGE, PER_PAGE) || []
    @by_day = @segments.group_by { |segment| @zone.at(segment.started_at).to_date }
    @colors = Api::TransitSegmentSerializer.colors_for(@segments)
  end

  def update
    review = Gtfs::SegmentReview.new(current_user, source: 'web')
    segment = if params[:trip_gtfs_id].present?
                review.call(params[:id], 'choose', trip_gtfs_id: params[:trip_gtfs_id], feed_id: params[:feed_id])
              else
                review.call(params[:id], params[:review_action])
              end
    notice = params[:trip_gtfs_id].present? ? t('.chosen') : t(".#{segment.status}")
    redirect_back_or_to transit_segments_path, notice:, status: :see_other
  rescue Gtfs::SegmentReview::NotFound
    redirect_back_or_to transit_segments_path, alert: t('.reload'), status: :see_other
  rescue Gtfs::SegmentReview::Invalid => e
    redirect_back_or_to transit_segments_path, alert: t('.invalid', message: e.message), status: :see_other
  end

  private

  def summary(segments)
    {
      count: segments.size,
      duration_s: segments.sum { |s| s.ended_at - s.started_at },
      distance_m: segments.sum { |s| s.distance_m.to_f },
      by_mode: segments.map(&:mode).tally.sort_by { |mode, count| [-count, mode] },
      uncertain: segments.count(&:uncertain?)
    }
  end
end
