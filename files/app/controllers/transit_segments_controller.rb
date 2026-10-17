# frozen_string_literal: true

# Spec 12.3: the detected rides as cards, with confirm / reject / undo and
# "another trip". All changes go through Gtfs::SegmentReview. A ride that was
# matched again meanwhile (review A2) gives a notice and a reloaded list.
class TransitSegmentsController < ApplicationController
  PERIODS = [7, 14, 30, 90, 365].freeze
  PER_PAGE = 30

  before_action :authenticate_user!

  def index
    @enabled = Gtfs::UserSettings.new(current_user).enabled?
    @days = PERIODS.include?(params[:days].to_i) ? params[:days].to_i : 14
    @only_uncertain = params[:uncertain] == '1'
    @page = [params[:page].to_i, 1].max
    scope = Gtfs::SegmentQuery.new(current_user, start_at: @days.days.ago.to_i).scope
    @total, @segments = @only_uncertain ? uncertain_page(scope) : [scope.count, page_of(scope).to_a]
    @colors = Api::TransitSegmentSerializer.colors_for(@segments)
    @zone = ActiveSupport::TimeZone[current_user.timezone_iana] || Time.zone
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

  # Paged in SQL (review A2).
  def page_of(scope)
    scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  # TransitSegment#uncertain? is computed in Ruby (thresholds and debug
  # flags), so only the auto rides of the period are loaded and filtered.
  def uncertain_page(scope)
    segments = scope.where(status: :auto).select(&:uncertain?)
    [segments.size, segments.slice((@page - 1) * PER_PAGE, PER_PAGE) || []]
  end
end
