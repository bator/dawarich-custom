# frozen_string_literal: true

# Daily track pick (added 2026-10-16): route "trackpick:*" button clicks of
# the existing GTFS Discord bot to TrackPick::DiscordHandler. Additive only;
# the GTFS handler code is not modified. Takes effect after a restart of
# dawarich-gtfs-discord-bot.
module TrackPickInteractionHook
  def prepare(interaction)
    return TrackPick::DiscordHandler.new.prepare(interaction) if TrackPick::DiscordHandler.track_pick?(interaction)

    super
  end
end

Rails.application.config.to_prepare do
  handler = Gtfs::Discord::InteractionHandler
  handler.prepend(TrackPickInteractionHook) unless handler.ancestors.include?(TrackPickInteractionHook)
end
