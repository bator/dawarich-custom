# frozen_string_literal: true

# The one row of /transit/discord. `data` holds page values under the names of
# the environment variables they replace (DISCORD_TRANSIT_CHANNEL_ID, ...), as
# strings; a name missing from it falls back to the environment. The bot token
# is in its own encrypted column and is never sent back to the page.
#
# Readers go through .cached: the web, worker and bot processes each keep the
# row for CACHE_SECONDS, so a save reaches all of them within that time
# without a query per Discord call.
class Gtfs::DiscordSetting < ApplicationRecord
  CACHE_SECONDS = 10

  encrypts :bot_token
  belongs_to :updated_by, class_name: 'User', optional: true

  @cache_lock = Mutex.new

  class << self
    def current
      find_or_create_by!(singleton: true)
    rescue ActiveRecord::RecordNotUnique
      find_by!(singleton: true)
    end

    # The row as read at most CACHE_SECONDS ago; nil before the first save or
    # while the table does not exist yet (before db:migrate).
    def cached
      @cache_lock.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @cached_at.nil? || now - @cached_at > CACHE_SECONDS
          @cached = load_row
          @cached_at = now
        end
        @cached
      end
    end

    def reset_cache!
      @cache_lock.synchronize { @cached_at = nil }
    end

    # Like ENV.fetch, with the page value first.
    def fetch(name, default = nil)
      data = cached&.data
      return data[name].to_s if data.is_a?(Hash) && data.key?(name)

      ENV.fetch(name, default)
    end

    def page_value?(name)
      data = cached&.data
      data.is_a?(Hash) && data.key?(name)
    end

    # The token saved on the page; nil when none, or when it cannot be
    # decrypted any more (rotated keys), so the environment's token applies.
    def token
      cached&.bot_token.presence
    rescue ActiveRecord::Encryption::Errors::Base
      nil
    end

    private

    def load_row
      find_by(singleton: true)
    rescue ActiveRecord::StatementInvalid
      nil
    end
  end
end
