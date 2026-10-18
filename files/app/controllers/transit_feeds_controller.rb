# frozen_string_literal: true

require 'sidekiq/api'

# /transit/feeds (admins only): read-only status of the GTFS feeds, the jobs
# of the `gtfs` Sidekiq queue and each opted-in user's history backfill.
# Enabling feeds stays a console/DB step (Gtfs::FeedRegistry seeds them off).
class TransitFeedsController < ApplicationController
  # A feed whose timetable ends within this many days gets a yellow badge.
  EXPIRY_WARNING_DAYS = 30
  QUEUE = 'gtfs'
  MAX_JOBS = 50
  # The retry set is shared by every queue; only its newest entries are
  # scanned for ours, so a huge retry set cannot stall the page.
  MAX_RETRY_SCAN = 1_000

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

  # One query for the states of every opted-in user instead of one per user.
  def backfills
    users = Gtfs::UserSettings.opted_in_users.order(:id).to_a
    states = Gtfs::UserState.where(user_id: users.map(&:id)).index_by(&:user_id)
    users.map { |user| [user, states[user.id]&.backfill || {}] }
  end
end
