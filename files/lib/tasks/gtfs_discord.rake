# frozen_string_literal: true

module GtfsDiscordTasks
  WATCH_SECONDS = 10

  # The token and the on/off switch can change on /transit/discord while the
  # bot runs. The gateway holds the token of its session, so on such a change
  # the bot stops and exits non-zero, and systemd starts it again (the other
  # settings are read on every use and need no restart).
  def self.watch_settings(gateway, logger)
    restart = Concurrent::Event.new
    started_with = Gtfs::Discord::Config.restart_fingerprint
    watcher = Thread.new do
      loop do
        sleep WATCH_SECONDS
        changed = Rails.application.executor.wrap { Gtfs::Discord::Config.restart_fingerprint != started_with }
        next unless changed

        logger.info('[GTFS discord] token or on/off switch changed on /transit/discord, restarting the bot')
        restart.set
        gateway.stop
        break
      rescue StandardError => e
        logger.warn("[GTFS discord] settings check failed: #{e.class}: #{e.message}")
      end
    end
    [watcher, restart]
  end
end

namespace :gtfs do
  desc 'Run the Discord transit bot (gateway connection for the approve/reject buttons)'
  task discord_bot: :environment do
    problems = Gtfs::Discord::Config.problems
    abort "Discord transit bot does not start: #{problems.join('; ')}" if problems.any?

    logger = Logger.new($stdout)
    Gtfs::Discord::Config.warnings.each { |warning| logger.warn("[GTFS discord] #{warning}") }
    gateway = Gtfs::Discord::Gateway.new(logger:)
    %w[INT TERM].each { |signal| Signal.trap(signal) { gateway.stop } }
    watcher, restart = GtfsDiscordTasks.watch_settings(gateway, logger)
    ok = gateway.run
    watcher.kill
    if restart.set?
      Gtfs::Discord::BotStatus.update!(:restarting)
      exit 3 # systemd (Restart=on-failure, RestartSec=30) starts the bot again with the new settings
    end
    exit 1 unless ok # fatal close code (bad token etc.): do not restart-loop silently

    Gtfs::Discord::BotStatus.update!(:stopped) # INT/TERM, e.g. systemctl stop
  end

  desc 'Edit messages of deleted/hidden rides to a neutral text: gtfs:discord_cleanup[USER_ID] (all users without)'
  task :discord_cleanup, [:user_id] => :environment do |_, args|
    abort 'Discord transit bot is disabled' unless Gtfs::Discord::Config.enabled?

    Gtfs::Discord::MessageCleanupJob.perform_now(args[:user_id].presence&.to_i)
    puts "tombstoned: #{TransitSegmentDiscordMessage.where.not(tombstoned_at: nil).count}, " \
         "hidden: #{TransitSegmentDiscordMessage.where.not(hidden_at: nil).count}"
  end

  desc 'Replace an old bot message whose ride is gone (no row any more) by the "deleted" text: ' \
       'gtfs:discord_tombstone[MESSAGE_ID]'
  task :discord_tombstone, [:message_id] => :environment do |_, args|
    abort 'Discord transit bot is disabled' unless Gtfs::Discord::Config.enabled?

    channel_id = Gtfs::Discord::Config.channel_id
    client = Gtfs::Discord::Client.new
    message = client.message(channel_id, args[:message_id])
    abort "message #{args[:message_id]} was not posted by this bot" if message.dig('author', 'id') != client.me['id']
    existing = TransitSegmentDiscordMessage.find_by(channel_id:, message_id: args[:message_id])
    if existing&.transit_segment_id
      abort "message #{args[:message_id]} belongs to segment #{existing.transit_segment_id}"
    end

    record = existing || TransitSegmentDiscordMessage.create!(channel_id:, message_id: args[:message_id])
    Gtfs::Discord::MessageCleanupJob.perform_now
    if record.reload.tombstoned_at
      puts "message #{args[:message_id]}: #{Gtfs::Discord::MessageBuilder::DELETED_TEXT}"
    else # e.g. Discord rate limit: the job was re-enqueued
      puts "message #{args[:message_id]}: not edited yet, run gtfs:discord_cleanup again in a minute"
    end
  end

  desc 'Post one ride to the Discord channel: gtfs:discord_post[SEGMENT_ID]'
  task :discord_post, [:segment_id] => :environment do |_, args|
    abort 'Discord transit bot is disabled' unless Gtfs::Discord::Config.enabled?

    segment = TransitSegment.find(args[:segment_id])
    record = Gtfs::Discord::NotifyJob.post(segment)
    puts record ? "posted segment #{segment.id}: message #{record.message_id}" : "segment #{segment.id} already posted"
  end

  desc 'Re-send the message of a posted ride (new map image, current status): gtfs:discord_refresh[SEGMENT_ID]'
  task :discord_refresh, [:segment_id] => :environment do |_, args|
    abort 'Discord transit bot is disabled' unless Gtfs::Discord::Config.enabled?

    record = TransitSegmentDiscordMessage.find_by!(transit_segment_id: args[:segment_id])
    Gtfs::Discord::SyncMessageJob.perform_now(record.transit_segment_id)
    puts "refreshed segment #{record.transit_segment_id}: message #{record.message_id}"
  end

  desc 'Write the map image of a ride to a file (no Discord): gtfs:discord_map[SEGMENT_ID,PATH]'
  task :discord_map, %i[segment_id path] => :environment do |_, args|
    segment = TransitSegment.find(args[:segment_id])
    map = Gtfs::Discord::RideMap.new(segment).call
    abort "segment #{segment.id}: nothing to draw" if map.empty?

    renderer = Gtfs::Discord::MapRenderer.new
    image = Gtfs::Discord::RideImage
    File.binwrite(args[:path], renderer.render(map, style: image.style(segment), color: image.color(segment)))
    puts "segment #{segment.id}: #{args[:path]} (zoom #{renderer.zoom}, line: #{map.line_source}, " \
         "#{map.gps.sum(&:size)} GPS points)"
  end

  desc 'Post the pending rides of a user now: gtfs:discord_notify[USER_ID]'
  task :discord_notify, [:user_id] => :environment do |_, args|
    Gtfs::Discord::NotifyJob.perform_now(args[:user_id].to_i)
  end
end
