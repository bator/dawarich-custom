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
    # Defaults; /transit/discord can replace them (TRACK_PICK_* in Gtfs::DiscordSetting).
    TARGET_EMAIL = 'minekte@crusand.org'
    SOURCE_EMAILS = %w[minekte@crusand.org toth.bator@crusand.org register@crusand.org].freeze
    MAX_SOURCES = 3 # one map colour each (COLORS)
    # only crusand may click, independent of the GTFS allow-list
    ALLOWED_DISCORD_USER_IDS = %w[212980510203314177].freeze
    # The cron script (/usr/local/sbin/dawarich-track-pick-daily) posts for real only while this
    # file exists; without it the daily run is a dry run. /transit/discord switches it.
    ENABLED_FILE = '/opt/dawarich/track-pick/ENABLED'
    # trackpick:<date>:<action>. Actions (the selection state travels in the custom_ids):
    #   d:<bp>         whole-day select (value = user id), <bp> = current inner-city pick
    #   b:<day>        inner-city select (value = user id | same), <day> = current whole-day pick
    #   ok:<day>:<bp>  confirm; skip = skip the day
    # Older messages: trackpick:<date> select (value = user id | skip), trackpick:<date>:<user id|skip> buttons.
    CUSTOM_ID = /\Atrackpick:(\d{4}-\d{2}-\d{2})(?::(.+))?\z/
    CHOICE = /\A(\d+|skip)\z/
    PICK = /\A(\d+|-)\z/ # a user id, or "-" for nothing picked yet
    BP_PICK = /\A(\d+|same)\z/
    GAP_SECONDS = 600 # a pause longer than this counts as a gap
    COLORS = ['#E4002B', '#0057B8', '#1A9E3F'].freeze

    def zone
      ActiveSupport::TimeZone[TIME_ZONE]
    end

    def target_email
      Gtfs::DiscordSetting.fetch('TRACK_PICK_TARGET_EMAIL', TARGET_EMAIL).presence || TARGET_EMAIL
    end

    def source_emails
      list('TRACK_PICK_SOURCE_EMAILS', SOURCE_EMAILS).first(MAX_SOURCES)
    end

    def allowed_discord_user_ids
      list('TRACK_PICK_ALLOWED_DISCORD_USER_IDS', ALLOWED_DISCORD_USER_IDS)
    end

    def enabled?
      File.exist?(ENABLED_FILE)
    end

    def enable!(on)
      if on
        FileUtils.mkdir_p(File.dirname(ENABLED_FILE))
        FileUtils.touch(ENABLED_FILE)
      else
        FileUtils.rm_f(ENABLED_FILE)
      end
    end

    def list(name, default)
      Gtfs::DiscordSetting.fetch(name, default.join(',')).split(',').map(&:strip).compact_blank
    end

    def target_user
      User.find_by!(email: target_email)
    end

    def source_users
      emails = source_emails
      by_email = User.where(email: emails).index_by(&:email)
      emails.filter_map { |e| by_email[e] }
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

    # [[date, decision], ...] of the last `days` days that have one, newest first (/transit/discord)
    def recent_decisions(days, today: zone.today)
      (1..days).filter_map do |n|
        date = today - n
        (found = decision(date)) && [date, found]
      end
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
