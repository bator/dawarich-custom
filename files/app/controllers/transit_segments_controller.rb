# frozen_string_literal: true

# Spec 12.3: the detected rides as a day-by-day timeline under a summary
# strip; each row opens to confirm / reject / undo and "another trip". All
# changes go through Gtfs::SegmentReview. A ride that was matched again
# meanwhile (review A2) gives a notice and a reloaded list.
class TransitSegmentsController < ApplicationController
  PERIODS = [7, 14, 30, 90, 365].freeze
  PER_PAGE = 50
  # The columns the summary strip and the uncertain filter need; the rows
  # themselves (with their debug jsonb) are only loaded for the current page.
  SUMMARY_COLUMNS = [
    :id, :status, :confidence, :route_type, :started_at, :ended_at, :distance_m,
    Arel.sql("transit_segments.debug->>'ambiguous'"),
    Arel.sql("transit_segments.debug->>'trip_ambiguous'"),
    Arel.sql("transit_segments.debug->'caps'")
  ].freeze

  before_action :authenticate_user!

  def index
    @enabled = Gtfs::UserSettings.new(current_user).enabled?
    @days = PERIODS.include?(params[:days].to_i) ? params[:days].to_i : 14
    @only_uncertain = params[:uncertain] == '1'
    @zone = ActiveSupport::TimeZone[current_user.timezone_iana] || Time.zone
    scope = Gtfs::SegmentQuery.new(current_user, start_at: @days.days.ago.to_i).scope
    # TransitSegment#uncertain? is computed in Ruby (thresholds and debug
    # flags), so the summary and the "only uncertain" filter work from a
    # pluck of the needed columns; the list itself is paged in SQL.
    rows = scope.pluck(*SUMMARY_COLUMNS)
    uncertain_ids = rows.select { |row| uncertain_row?(row) }.map(&:first)
    @summary = summary(rows, uncertain_ids.size)
    listed = @only_uncertain ? scope.where(id: uncertain_ids) : scope
    @total = @only_uncertain ? uncertain_ids.size : rows.size
    @page = params[:page].to_i.clamp(1, [(@total - 1) / PER_PAGE + 1, 1].max)
    @segments = listed.offset((@page - 1) * PER_PAGE).limit(PER_PAGE).to_a
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

  # Mirrors TransitSegment#uncertain? on a plucked row.
  def uncertain_row?(row)
    _id, status, confidence, _route_type, _started_at, _ended_at, _distance_m, ambiguous, trip_ambiguous, caps = row
    return false unless status == 'auto'

    caps = JSON.parse(caps) if caps.is_a?(String)
    confidence < Gtfs::Config::AUTO_ACCEPT || ambiguous == 'true' || trip_ambiguous == 'true' || Array(caps).any?
  end

  def summary(rows, uncertain_count)
    {
      count: rows.size,
      duration_s: rows.sum { |row| row[5] - row[4] },
      distance_m: rows.sum { |row| row[6].to_f },
      by_mode: rows.map { |row| TransitSegment.mode_for(row[3]) }.tally.sort_by { |mode, count| [-count, mode] },
      uncertain: uncertain_count
    }
  end
end
