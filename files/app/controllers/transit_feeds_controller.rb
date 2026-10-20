# frozen_string_literal: true

require 'sidekiq/api'

# /transit/feeds (admins only): read-only status of the GTFS feeds, the jobs
# of the `gtfs` Sidekiq queue and each opted-in user's history backfill.
# Enabling feeds stays a console/DB step (Gtfs::FeedRegistry seeds them off).
# The page leads with what needs attention (expired, expiring, failed), then
# the feeds rides actually come from, then the rest as compact tiles.
class TransitFeedsController < ApplicationController
  # A feed whose timetable ends within this many days gets a yellow badge.
  EXPIRY_WARNING_DAYS = 30
  # Window of the validity timeline, in days before and after today.
  WINDOW_PAST = 60
  WINDOW_FUTURE = 120
  QUEUE = 'gtfs'
  MAX_JOBS = 50
  # The retry set is shared by every queue; only its newest entries are
  # scanned for ours, so a huge retry set cannot stall the page.
  MAX_RETRY_SCAN = 1_000
  # Rides counted for "in use": the last USAGE_DAYS days, and a weekly
  # sparkline over SPARK_WEEKS weeks.
  USAGE_DAYS = 30
  # A feed with a problem gets a big card only when it matters: a ride came
  # from it in RELEVANT_DAYS, or a user picked it in their transit settings.
  RELEVANT_DAYS = 90
  SPARK_WEEKS = 12
  TOP_LINES = 3
  MAX_LINE_SAMPLE = 2_000

  before_action :authenticate_user!
  before_action :authenticate_admin!

  def index
    @zone = ActiveSupport::TimeZone[current_user.timezone_iana] || Time.zone
    @today = @zone.today
    @feeds = Gtfs::Feed.order(enabled: :desc, key: :asc).to_a
    @queue_size, @queued = queued_jobs
    @running = running_jobs
    @retries, @retries_capped = retry_count
    @backfills = backfills
    @usage = feed_usage
    @routes = route_summary
    @selected_keys = Gtfs::UserSettings.opted_in_users.flat_map { |user| Array(Gtfs::UserSettings.new(user).feed_keys) }.uniq
  end

  private

  def queued_jobs
    queue = Sidekiq::Queue.new(QUEUE)
    [queue.size, queue.first(MAX_JOBS)]
  end

  def running_jobs
    Sidekiq::WorkSet.new.filter_map { |_process, _thread, work| work if work.queue == QUEUE }
  end

  # [count, capped?]: capped when the retry set had more entries than scanned.
  def retry_count
    retry_set = Sidekiq::RetrySet.new
    count = retry_set.lazy.take(MAX_RETRY_SCAN).count { |job| job.queue == QUEUE }
    [count, retry_set.size > MAX_RETRY_SCAN]
  end

  # Rides per feed (all time and the last USAGE_DAYS days, rejected ones not
  # counted), rides per week for the sparkline, and the most ridden lines with
  # one sample segment each (for the line badge in the route colour).
  def feed_usage
    rides = TransitSegment.where.not(status: :rejected)
    since = (@today - USAGE_DAYS).in_time_zone(@zone).to_i
    week_start = @today.beginning_of_week - (SPARK_WEEKS - 1).weeks
    weekly = Hash.new { |hash, key| hash[key] = Array.new(SPARK_WEEKS, 0) }
    rides.where(started_at: week_start.in_time_zone(@zone).to_i..).pluck(:feed_id, :started_at).each do |feed_id, at|
      week = (@zone.at(at).to_date - week_start).to_i / 7
      weekly[feed_id][week] += 1 if week.between?(0, SPARK_WEEKS - 1)
    end
    sample = rides.order(started_at: :desc).limit(MAX_LINE_SAMPLE).to_a
    lines = sample.group_by(&:feed_id).transform_values do |list|
      # by the name riders see: one line can have several route ids (MÁV 9057)
      list.group_by { |s| s.route_short_name.presence || s.route_long_name }
          .map { |_, group| [group.first, group.size] }.sort_by { |_, n| -n }.first(TOP_LINES)
    end
    @colors = Api::TransitSegmentSerializer.colors_for(lines.values.flatten(1).map(&:first))
    relevant_since = (@today - RELEVANT_DAYS).in_time_zone(@zone).to_i
    { total: rides.group(:feed_id).count, recent: rides.where(started_at: since..).group(:feed_id).count,
      relevant: rides.where(started_at: relevant_since..).group(:feed_id).count, weekly:, lines:, week_start: }
  end

  # {feed_id => {count:, modes: {mode => routes}}} of each feed's active version.
  def route_summary
    counts = Gtfs::Route.joins(:feed).where('gtfs_routes.version = gtfs_feeds.active_version')
                        .group('gtfs_routes.feed_id', 'gtfs_routes.route_type').count
    counts.each_with_object({}) do |((feed_id, type), n), summary|
      entry = summary[feed_id] ||= { count: 0, modes: Hash.new(0) }
      entry[:count] += n
      entry[:modes][TransitSegment.mode_for(type)] += n
    end
  end

  # One query for the states of every opted-in user instead of one per user.
  def backfills
    users = Gtfs::UserSettings.opted_in_users.order(:id).to_a
    states = Gtfs::UserState.where(user_id: users.map(&:id)).index_by(&:user_id)
    users.map { |user| [user, states[user.id]&.backfill || {}] }
  end
end
