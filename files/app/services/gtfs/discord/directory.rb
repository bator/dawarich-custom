# frozen_string_literal: true

# Names and avatars for /transit/discord, so the page shows the bot's avatar,
# "@crusand" and "#dawarich" instead of bare snowflakes. Looked up with the bot
# token (GET /users/@me, /users/:id, /channels/:id) and cached per token. A
# failed lookup is remembered for MISS_TTL; the page then shows the bare id.
module Gtfs::Discord::Directory
  module_function

  TTL = 6.hours
  MISS_TTL = 10.minutes
  TIMEOUT = 3 # seconds per request; the page must not hang on Discord
  CDN = 'https://cdn.discordapp.com'

  Person = Struct.new(:id, :name, :username, :avatar_url, :known, keyword_init: true)

  def bot
    data = lookup('me', &:me)
    data && person(data)
  end

  def user(id)
    data = lookup("user:#{id}") { |client| client.user(id) }
    return person(data) if data

    Person.new(id: id.to_s, name: nil, username: nil, avatar_url: default_avatar(id), known: false)
  end

  # The channel's name, or nil when it cannot be looked up.
  def channel_name(id)
    return nil if id.blank?

    lookup("channel:#{id}") { |client| client.channel(id) }&.fetch('name', nil)
  end

  def person(data)
    id = data['id'].to_s
    avatar = data['avatar'].presence
    Person.new(id:, name: data['global_name'].presence || data['username'], username: data['username'],
               avatar_url: avatar ? "#{CDN}/avatars/#{id}/#{avatar}.png?size=64" : default_avatar(id), known: true)
  end

  # Discord's default avatar for accounts without one.
  def default_avatar(id)
    "#{CDN}/embed/avatars/#{(id.to_i >> 22) % 6}.png"
  end

  # Cached response fields, {} remembered for a miss.
  def lookup(key)
    token = Gtfs::Discord::Config.token
    return nil if token.blank?

    cache_key = "gtfs:discord:directory:#{Digest::SHA256.hexdigest(token)[0, 12]}:#{key}"
    cached = Rails.cache.read(cache_key)
    return cached.presence unless cached.nil?

    data = yield(Gtfs::Discord::Client.new(token:, timeout: TIMEOUT))
    data = data.slice('id', 'username', 'global_name', 'avatar', 'name')
    Rails.cache.write(cache_key, data, expires_in: TTL)
    data
  rescue StandardError => e
    Rails.logger.warn("[GTFS discord] directory lookup #{key} failed: #{e.class}")
    begin
      Rails.cache.write(cache_key, {}, expires_in: MISS_TTL) if cache_key
    rescue StandardError
      nil
    end
    nil
  end
end
