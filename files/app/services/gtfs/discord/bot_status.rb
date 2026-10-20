# frozen_string_literal: true

# Liveness of the gtfs:discord_bot process for /transit/discord. The bot is a
# process of its own, so it reports through the Rails cache (Redis): on READY
# and RESUMED, on every heartbeat ACK (about every 41 s), while it waits to
# reconnect, and when it stops. The entry expires TTL after the last write,
# so a bot that died without a word shows as not running.
module Gtfs::Discord::BotStatus
  module_function

  KEY = 'gtfs:discord:bot_status'
  TTL = 3.minutes

  def connected!(username)
    # braces: without them Ruby 3 passes the string-keyed hash as keywords
    write({ 'state' => 'connected', 'bot' => username, 'since' => Time.current.iso8601 })
  end

  def beat!
    current = read
    write(current.merge('beat_at' => Time.current.iso8601)) if current
  end

  # state: connected | reconnecting | restarting | stopped | fatal
  def update!(state, message: nil, ttl: TTL)
    write((read || {}).merge('state' => state.to_s, 'message' => message), ttl:)
  end

  # { 'state', 'bot', 'since', 'beat_at', 'message', 'at', 'pid' } or nil
  def read
    Rails.cache.read(KEY)
  rescue StandardError
    nil
  end

  def write(status, ttl: TTL)
    Rails.cache.write(KEY, status.merge('at' => Time.current.iso8601, 'pid' => Process.pid), expires_in: ttl)
  rescue StandardError
    nil # a cache outage must never take the bot down
  end
end
