# frozen_string_literal: true

# Known feed definitions from config/gtfs_feeds.yml. URLs come from the file
# or from an environment variable (`url_env`); credentials only from
# environment variables, never from the database or the repository.
class Gtfs::FeedRegistry
  CONFIG_PATH = Rails.root.join('config/gtfs_feeds.yml')

  def self.definitions
    @definitions ||= begin
      raw = YAML.safe_load_file(CONFIG_PATH, aliases: false) || {}
      raw.fetch('feeds', {}).to_h { |key, value| [key.to_s, value.to_h.transform_keys(&:to_s).freeze] }.freeze
    end
  end

  def self.definition(key)
    definitions[key.to_s]
  end

  def self.reset!
    @definitions = nil
  end

  # Creates missing feeds (disabled) and refreshes name/URL/attribution of
  # existing ones. Never changes `enabled` or `import_shapes` of an existing
  # feed: that is the admin's decision. That holds when a feed's URL env
  # variable is (temporarily) unset too (review A4): the feed keeps its
  # `enabled` flag, gets no URL and is skipped by SyncAllFeedsJob until the
  # variable is set again and seed_feeds runs, so no re-enabling is needed.
  def self.seed!
    definitions.map do |key, definition|
      feed = Gtfs::Feed.find_or_initialize_by(key:)
      url = resolve_url(definition)
      feed.assign_attributes(
        name: definition['name'] || key,
        source_url: url,
        attribution: definition['attribution'],
        license_url: definition['license_url'],
        timezone: feed.timezone.presence || definition['timezone'] || 'Europe/Budapest'
      )
      if feed.new_record?
        feed.enabled = false
        feed.import_shapes = definition.fetch('import_shapes', true)
      end
      feed.save!
      feed
    end
  end

  def self.resolve_url(definition)
    from_env = definition['url_env'].present? ? ENV[definition['url_env']].presence : nil
    from_env || definition['url'].presence
  end

  # Headers / query parameters for authenticated sources.
  # auth: { type: basic, username_env: X, password_env: Y }
  #       { type: header, name: Authorization, env: X, prefix: "Bearer " }
  #       { type: query, name: key, env: X }
  def self.auth_for(key)
    auth = definition(key)&.fetch('auth', nil)
    return {} if auth.blank?

    case auth['type']
    when 'basic'
      user = ENV[auth['username_env'].to_s].presence
      pass = ENV[auth['password_env'].to_s].presence
      user && pass ? { basic: [user, pass] } : {}
    when 'header'
      value = ENV[auth['env'].to_s].presence
      value ? { headers: { auth['name'] => "#{auth['prefix']}#{value}" } } : {}
    when 'query'
      value = ENV[auth['env'].to_s].presence
      value ? { query: { auth['name'] => value } } : {}
    else
      {}
    end
  end

  def self.user_agent_for(key)
    env = definition(key)&.fetch('user_agent_env', nil)
    (env && ENV[env].presence) || "Dawarich/#{APP_VERSION} gtfs-importer"
  end
end
