# frozen_string_literal: true

# /transit/discord (admins only): the Discord bot that posts detected rides with
# approve/reject buttons, and the daily track_pick message. Shows whether the
# bot runs and why not, and edits its settings (Gtfs::DiscordSetting, which wins
# over /opt/dawarich/gtfs.env). The token is write-only: the page says where it
# comes from, never what it is.
class TransitDiscordController < ApplicationController
  SNOWFLAKE = /\A\d{17,20}\z/
  MAX_AGE_HOURS = 1..720
  MAX_PER_RUN = 1..50
  UNCERTAIN_CHOICES = (10..19).map { |i| (i * 0.05).round(2) }.freeze
  RECENT_MESSAGES = 8
  RECENT_DECISION_DAYS = 7
  STATS_DAYS = 30

  before_action :authenticate_user!
  before_action :authenticate_admin!

  rate_limit to: 5, within: 10.minutes, only: :test_message, by: -> { "transit-discord-test:#{current_user.id}" },
             with: -> { redirect_to transit_discord_path, alert: t('transit_discord.flash.rate_limited') }

  def show
    @status = Gtfs::Discord::BotStatus.read
    @problems = Gtfs::Discord::Config.problems
    @warnings = Gtfs::Discord::Config.warnings
    @setting = Gtfs::DiscordSetting.find_by(singleton: true)
    @users = User.order(:email).to_a
    @messages = TransitSegmentDiscordMessage.includes(:transit_segment).where.not(message_id: nil)
                                            .order(created_at: :desc).limit(RECENT_MESSAGES)
    @counts = TransitSegmentDiscordMessage.where(created_at: STATS_DAYS.days.ago..).where.not(message_id: nil)
                                          .group(:last_status).count
    @decisions = TrackPick::Config.recent_decisions(RECENT_DECISION_DAYS)
    segments = @messages.filter_map(&:transit_segment)
    @colors = Api::TransitSegmentSerializer.colors_for(segments)
    lookup_discord_names
    build_preview(segments.first || TransitSegment.order(started_at: :desc).first)
  end

  def update
    values, errors = submitted_values
    return redirect_to(transit_discord_path, alert: errors.join(' ')) if errors.any?

    setting = Gtfs::DiscordSetting.current
    attributes = { data: setting.data.merge(values), updated_by: current_user }
    token = discord_params[:bot_token].to_s.strip
    if token.present?
      attributes[:bot_token] = token
    elsif discord_params[:clear_token] == '1'
      attributes[:bot_token] = nil
    end
    setting.update!(attributes)
    TrackPick::Config.enable!(discord_params[:track_pick_enabled] == 'true')
    Gtfs::DiscordSetting.reset_cache!
    redirect_to transit_discord_path, notice: t('transit_discord.flash.saved')
  end

  def test_message
    token = Gtfs::Discord::Config.token
    channel = Gtfs::Discord::Config.channel_id
    return redirect_to(transit_discord_path, alert: t('transit_discord.flash.test_unconfigured')) if token.blank? || channel.blank?

    content = t('transit_discord.flash.test_content', user: Gtfs::Discord::Config.user_label(current_user))
    Gtfs::Discord::Client.new(token:).post_message(channel, { content:, allowed_mentions: { parse: [] } })
    redirect_to transit_discord_path, notice: t('transit_discord.flash.test_sent')
  rescue StandardError => e
    reason = e.respond_to?(:status) && e.status ? "HTTP #{e.status}" : e.class.name
    redirect_to transit_discord_path, alert: t('transit_discord.flash.test_failed', reason:)
  end

  private

  # Avatars and names instead of snowflakes (cached Discord lookups).
  def lookup_discord_names
    directory = Gtfs::Discord::Directory
    @bot = directory.bot
    @channel_name = directory.channel_name(Gtfs::Discord::Config.channel_id)
    @approvers = Gtfs::Discord::Config.allowed_discord_user_ids.map { |id| directory.user(id) }
    @pickers = TrackPick::Config.allowed_discord_user_ids.map { |id| directory.user(id) }
  end

  # The message a ride gets, built by the bot's own builder from a recent ride.
  def build_preview(segment)
    return unless segment

    image = 'map.png' if Gtfs::Discord::Config.map_enabled?
    @preview = Gtfs::Discord::MessageBuilder.new(segment, image:).preview_payload
    @preview_segment = segment
  rescue StandardError => e
    Rails.logger.warn("[GTFS discord] preview of segment #{segment&.id} failed: #{e.class}: #{e.message}")
    @preview = nil
  end

  def discord_params
    params.fetch(:discord, {}).permit(
      :enabled, :bot_token, :clear_token, :channel_id, :posted_users, :allowed_discord_user_ids,
      :max_age_hours, :max_per_run, :map, :uncertain_below,
      :track_pick_enabled, :track_pick_target_email, :track_pick_allowed_discord_user_ids,
      posted_user_ids: [], track_pick_source_emails: []
    )
  end

  # The values to store, under the environment variable names they replace,
  # plus the list of problems (nothing is stored when there is one).
  def submitted_values
    p = discord_params
    errors = []
    enabled = p[:enabled] == 'true'
    emails = User.pluck(:email)

    channel = p[:channel_id].to_s.strip
    errors << t('transit_discord.errors.channel_id') unless channel.empty? || channel.match?(SNOWFLAKE)

    approvers = snowflakes(p[:allowed_discord_user_ids])
    errors << t('transit_discord.errors.discord_ids', field: t('transit_discord.show.approvers_label')) if approvers.nil?
    errors << t('transit_discord.errors.approvers_required') if enabled && approvers&.empty?

    max_age = Integer(p[:max_age_hours].to_s, exception: false)
    errors << t('transit_discord.errors.max_age', range: MAX_AGE_HOURS.minmax.join('–')) unless MAX_AGE_HOURS.cover?(max_age)
    per_run = Integer(p[:max_per_run].to_s, exception: false)
    errors << t('transit_discord.errors.max_per_run', range: MAX_PER_RUN.minmax.join('–')) unless MAX_PER_RUN.cover?(per_run)
    uncertain = Float(p[:uncertain_below].to_s, exception: false)&.round(2)
    errors << t('transit_discord.errors.uncertain') unless UNCERTAIN_CHOICES.include?(uncertain)

    posted = if p[:posted_users] == 'all'
               'all'
             else
               (Array(p[:posted_user_ids]).filter_map { |id| Integer(id, exception: false) } & User.pluck(:id)).sort.join(',')
             end

    target = p[:track_pick_target_email].to_s
    errors << t('transit_discord.errors.target') unless emails.include?(target)
    sources = Array(p[:track_pick_source_emails]).compact_blank.uniq
    if sources.empty? || sources.size > TrackPick::Config::MAX_SOURCES || (sources - emails).any?
      errors << t('transit_discord.errors.sources', max: TrackPick::Config::MAX_SOURCES)
    end
    pickers = snowflakes(p[:track_pick_allowed_discord_user_ids])
    errors << t('transit_discord.errors.discord_ids', field: t('transit_discord.show.pickers_label')) if pickers.nil?
    errors << t('transit_discord.errors.pickers_required') if pickers&.empty?

    values = {
      'DISCORD_TRANSIT_ENABLED' => enabled.to_s,
      'DISCORD_TRANSIT_CHANNEL_ID' => channel,
      'DISCORD_TRANSIT_USER_IDS' => posted,
      'DISCORD_TRANSIT_ALL_USERS' => 'false', # "all" is in DISCORD_TRANSIT_USER_IDS
      'DISCORD_TRANSIT_ALLOWED_DISCORD_USER_IDS' => approvers&.join(','),
      'DISCORD_TRANSIT_MAX_AGE_HOURS' => max_age.to_s,
      'DISCORD_TRANSIT_MAX_PER_RUN' => per_run.to_s,
      'DISCORD_TRANSIT_MAP' => (p[:map] == 'true').to_s,
      'GTFS_DISCORD_UNCERTAIN_BELOW' => format('%.2f', uncertain.to_f),
      'TRACK_PICK_TARGET_EMAIL' => target,
      'TRACK_PICK_SOURCE_EMAILS' => sources.join(','),
      'TRACK_PICK_ALLOWED_DISCORD_USER_IDS' => pickers&.join(',')
    }
    [values, errors]
  end

  # Discord user ids from "1, 2 3"; nil when one of them is not an id.
  def snowflakes(text)
    ids = text.to_s.split(/[\s,;]+/).compact_blank.uniq
    ids.all? { |id| id.match?(SNOWFLAKE) } ? ids : nil
  end
end
