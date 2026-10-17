# frozen_string_literal: true

# Daily "pick a track" feature (added 2026-10-16, separate from GTFS matching).
# Every morning the previous day's tracks of three users are compared and
# posted through the existing Dawarich Discord bot (same token/channel as
# gtfs:discord_bot). crusand picks one; the picked user's points of that day
# are copied (INSERT only, dedup by timestamp) onto the target account.
module TrackPick
  module Config
    module_function

    TIME_ZONE = 'Europe/Budapest'
    TARGET_EMAIL = 'minekte@crusand.org'
    SOURCE_EMAILS = %w[minekte@crusand.org toth.bator@crusand.org register@crusand.org].freeze
    # only crusand may click, independent of the GTFS allow-list
    ALLOWED_DISCORD_USER_IDS = %w[212980510203314177].freeze
    # select menu: trackpick:<date> (+ value); old buttons: trackpick:<date>:<user id|skip>
    CUSTOM_ID = /\Atrackpick:(\d{4}-\d{2}-\d{2})(?::(\d+|skip))?\z/
    CHOICE = /\A(\d+|skip)\z/
    GAP_SECONDS = 600 # a pause longer than this counts as a gap
    COLORS = ['#E4002B', '#0057B8', '#1A9E3F'].freeze

    def zone
      ActiveSupport::TimeZone[TIME_ZONE]
    end

    def target_user
      User.find_by!(email: TARGET_EMAIL)
    end

    def source_users
      by_email = User.where(email: SOURCE_EMAILS).index_by(&:email)
      SOURCE_EMAILS.filter_map { |e| by_email[e] }
    end

    def day_range(date)
      from = zone.local(date.year, date.month, date.day)
      [from.to_i, (from + 1.day).to_i]
    end

    def channel_id
      Gtfs::Discord::Config.channel_id
    end

    def token
      Gtfs::Discord::Config.token
    end

    STATE_DIR = '/opt/dawarich/track-pick/state'

    def decided_path(date)
      File.join(STATE_DIR, "decided-#{date.iso8601}")
    end

    # { 'choice' =>, 'user' =>, 'time' =>, 'inserted' => } or nil
    def decision(date)
      raw = File.read(decided_path(date))
      begin
        JSON.parse(raw)
      rescue JSON::ParserError
        { 'choice' => raw.strip }
      end
    rescue Errno::ENOENT
      nil
    end

    # first decision wins (exclusive create); returns false if already decided
    def record_decision!(date, choice:, user:, inserted:, time: zone.now)
      FileUtils.mkdir_p(STATE_DIR)
      File.open(decided_path(date), File::WRONLY | File::CREAT | File::EXCL) do |f|
        f.write(JSON.generate(choice:, user:, time: time.iso8601, inserted:) + "\n")
      end
      true
    rescue Errno::EEXIST
      false
    end

    # serialises decisions (check + copy + record) across bot threads/processes
    def with_decision_lock(date)
      FileUtils.mkdir_p(STATE_DIR)
      File.open(File.join(STATE_DIR, ".lock-#{date.iso8601}"), File::RDWR | File::CREAT) do |f|
        f.flock(File::LOCK_EX)
        yield
      end
    end

    def decided_text(decision)
      t = (Time.zone.parse(decision['time'].to_s)&.in_time_zone(zone)&.strftime('%H:%M') rescue nil)
      "#{decision['choice']}#{t ? " (#{t}, #{decision['user']})" : ''}"
    end

    def handle(user)
      user.email.to_s.split('@').first
    end
  end
end
