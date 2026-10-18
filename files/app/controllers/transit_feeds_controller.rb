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

  before_action :authenticate_user!
  before_action :authenticate_admin!

  def index
    @zone = ActiveSupport::TimeZone[current_user.timezone_iana] || Time.zone
    @today = @zone.today
    @feeds = Gtfs::Feed.order(enabled: :desc, key: :asc).to_a
    @queue_size, @queued = queued_jobs
    @running = running_jobs
    @retries = Sidekiq::RetrySet.new.count { |job| job.queue == QUEUE }
    @backfills = Gtfs::UserSettings.opted_in_users.order(:id).map { |user| [user, Gtfs::Backfill.status(user)] }
  end

  private

  def queued_jobs
    queue = Sidekiq::Queue.new(QUEUE)
    [queue.size, queue.first(MAX_JOBS)]
  end

  def running_jobs
    Sidekiq::WorkSet.new.filter_map { |_process, _thread, work| work if work.queue == QUEUE }
  end
end
