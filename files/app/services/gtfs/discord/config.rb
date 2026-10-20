# frozen_string_literal: true

# Discord approve/reject buttons for detected rides (Phase 3). Off by default.
#
#   DISCORD_TRANSIT_ENABLED=true            master switch
#   DISCORD_BOT_TOKEN                       bot token (never logged)
#   DISCORD_TRANSIT_CHANNEL_ID              channel the messages go to
#   DISCORD_TRANSIT_USER_IDS=2              Dawarich user ids whose new rides are posted automatically,
#                                           or "all": every user whose day gets matched
#   DISCORD_TRANSIT_ALL_USERS=false         same as DISCORD_TRANSIT_USER_IDS=all
#   DISCORD_TRANSIT_ALLOWED_DISCORD_USER_IDS  Discord user ids allowed to click; required: with an empty
#                                           list the bot does not start and nothing is posted (review H1)
#   DISCORD_TRANSIT_APP_URL                 base URL for the map links (default from APPLICATION_PROTOCOL/HOSTS)
#   DISCORD_TRANSIT_MAX_AGE_HOURS=72        rides older than this are not posted automatically
#   DISCORD_TRANSIT_MAX_PER_RUN=10
#   DISCORD_TRANSIT_MAP=true                map image of the ride in the message (rendered in the app)
#   DISCORD_TRANSIT_LOCALE=hu               language of the messages: hu or en (Gtfs::Discord::Texts)
#   GTFS_DISCORD_UNCERTAIN_BELOW=0.90       "bizonytalan" (and the orange line) only below this confidence
#   GTFS_MAP_TILE_URL                       PNG raster tiles {z}/{x}/{y} (default: OpenStreetMap)
#   GTFS_MAP_TILE_CONTACT                   operator contact for the tile server's User-Agent (OSM policy),
#                                           e.g. an e-mail address; default: the app URL
#   GTFS_MAP_TILE_USER_AGENT                full User-Agent instead of the generated one
#   GTFS_MAP_TILE_CACHE_DAYS=30             tile cache lifetime (at least 7 days)
#   GTFS_MAP_TILE_CACHE_DIR                 tile cache directory (default storage/map_tiles, a volume in compose)
#
# All of these except DISCORD_TRANSIT_APP_URL and GTFS_MAP_TILE_* can also be set on /transit/discord
# (admins). A value saved there wins over the environment (Gtfs::DiscordSetting).
module Gtfs::Discord::Config
  module_function

  def enabled?
    problems.empty?
  end

  # Why the Discord integration is off (empty when it is on); never
  # includes the token itself.
  def problems
    list = []
    list << 'DISCORD_TRANSIT_ENABLED is not true' unless switched_on?
    list << 'DISCORD_BOT_TOKEN is not set' if token.blank?
    list << 'DISCORD_TRANSIT_CHANNEL_ID is not set' if channel_id.blank?
    if allowed_discord_user_ids.empty?
      list << 'DISCORD_TRANSIT_ALLOWED_DISCORD_USER_IDS is empty (who may approve rides?)'
    end
    list
  end

  # The master switch alone (enabled? also needs token, channel and approvers).
  def switched_on?
    setting('DISCORD_TRANSIT_ENABLED', 'false') == 'true'
  end

  # Posting automatically for this user's rides.
  def enabled_for?(user)
    enabled? && posts_for?(user)
  end

  # Listed users, or with "all" every user (matching, and so posting after
  # it, only runs for users who opted in).
  def posts_for?(user)
    all_users? || user_ids.include?(user.id)
  end

  def all_users?
    setting('DISCORD_TRANSIT_ALL_USERS', 'false') == 'true' ||
      list('DISCORD_TRANSIT_USER_IDS').any? { |id| id.casecmp?('all') }
  end

  def token
    Gtfs::DiscordSetting.token || ENV['DISCORD_BOT_TOKEN'].presence
  end

  # :page, :env or nil (no token at all); never the token itself.
  def token_source
    return :page if Gtfs::DiscordSetting.token
    return :env if ENV['DISCORD_BOT_TOKEN'].present?

    nil
  end

  # Changes when the bot has to reconnect or stop: another token, or the
  # integration switched on or off. The bot process watches it.
  def restart_fingerprint
    Digest::SHA256.hexdigest([token.to_s, problems.empty?].join("\0"))
  end

  def channel_id
    setting('DISCORD_TRANSIT_CHANNEL_ID').presence
  end

  def user_ids
    list('DISCORD_TRANSIT_USER_IDS').filter_map { |id| Integer(id, exception: false) }
  end

  def allowed_discord_user_ids
    list('DISCORD_TRANSIT_ALLOWED_DISCORD_USER_IDS')
  end

  # Who owns the ride, for the message: full name, else the email's handle
  # (never the whole address).
  def user_label(user)
    [user.first_name, user.last_name].compact_blank.join(' ').presence || user.email.to_s.split('@').first
  end

  def max_age
    setting('DISCORD_TRANSIT_MAX_AGE_HOURS', '72').to_i.hours
  end

  def max_per_run
    setting('DISCORD_TRANSIT_MAX_PER_RUN', '10').to_i.clamp(1, 50)
  end

  def app_url
    configured = ENV['DISCORD_TRANSIT_APP_URL'].presence
    return configured.delete_suffix('/') if configured

    host = ENV['DOMAIN'].presence || ENV.fetch('APPLICATION_HOSTS', 'localhost').split(',').first.strip
    "#{ENV.fetch('APPLICATION_PROTOCOL', 'http')}://#{host}"
  end

  # Display only: the matcher's TransitSegment#uncertain? (below
  # GTFS_MATCH_AUTO_ACCEPT, or ambiguous, or flagged) stays as it is; the
  # Discord message calls a ride uncertain only if it is that AND its
  # confidence is below this threshold.
  def uncertain_below
    Float(setting('GTFS_DISCORD_UNCERTAIN_BELOW', '0.90'), exception: false)&.clamp(0.0, 1.0) || 0.9
  end

  def show_uncertain?(segment)
    segment.uncertain? && segment.confidence < uncertain_below
  end

  def map_enabled?
    setting('DISCORD_TRANSIT_MAP', 'true') != 'false'
  end

  # Language of the messages (Gtfs::Discord::Texts::LOCALES), whatever the
  # locale of the request or job that builds them.
  def locale
    value = setting('DISCORD_TRANSIT_LOCALE', Gtfs::Discord::Texts::DEFAULT).to_s
    Gtfs::Discord::Texts::LOCALES.key?(value) ? value : Gtfs::Discord::Texts::DEFAULT
  end

  def tile_url
    ENV['GTFS_MAP_TILE_URL'].presence || 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'
  end

  # OSM tile usage policy: an identifying User-Agent with a way to contact
  # the operator.
  def tile_user_agent
    ENV['GTFS_MAP_TILE_USER_AGENT'].presence ||
      "Dawarich-transit-preview/1.0 (self-hosted Dawarich #{app_url}; contact: #{tile_contact}; " \
      '+https://github.com/Freika/dawarich)'
  end

  def tile_contact
    ENV['GTFS_MAP_TILE_CONTACT'].presence || app_url
  end

  # Configuration that works but should be fixed (logged by the bot).
  def warnings
    list = []
    if ENV['GTFS_MAP_TILE_CONTACT'].blank? && ENV['GTFS_MAP_TILE_USER_AGENT'].blank? &&
       tile_url.include?('tile.openstreetmap.org')
      list << 'set GTFS_MAP_TILE_CONTACT (OpenStreetMap tile policy: a contact in the User-Agent)'
    end
    list
  end

  def tile_cache_days
    [ENV.fetch('GTFS_MAP_TILE_CACHE_DAYS', '30').to_i, 7].max
  end

  def tile_cache_dir
    ENV['GTFS_MAP_TILE_CACHE_DIR'].presence || Rails.root.join('storage/map_tiles').to_s
  end

  def list(name)
    setting(name, '').split(',').map(&:strip).compact_blank
  end

  # Page value (/transit/discord) first, then the environment.
  def setting(name, default = nil)
    Gtfs::DiscordSetting.fetch(name, default)
  end
end
