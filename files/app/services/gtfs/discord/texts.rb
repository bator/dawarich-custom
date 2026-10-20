# frozen_string_literal: true

# The texts of the bot's Discord messages in the language picked on
# /transit/discord (Gtfs::Discord::Config.locale; since 2026-10-20, Hungarian
# before and by default). Not I18n: the app has no `hu` locale
# (config.i18n.available_locales), so its translations are not even loaded,
# and the bot speaks the channel's language, not the viewer's.
# Texts: config/gtfs_discord_texts.yml.
module Gtfs::Discord::Texts
  # language => its own name, for the page's dropdown
  LOCALES = { 'hu' => 'Magyar', 'en' => 'English' }.freeze
  DEFAULT = 'hu'

  module_function

  # The text under `key` ("mode.bus") with its %{placeholders} filled in;
  # a key missing in one language falls back to the default one.
  def t(key, locale = Gtfs::Discord::Config.locale, **values)
    path = key.to_s.split('.')
    template = table.dig(locale.to_s, *path)
    template = table.dig(DEFAULT, *path) unless template.is_a?(String)
    raise KeyError, "no Discord text #{key}" unless template.is_a?(String)

    values.empty? ? template : I18n.interpolate(template, values)
  end

  def table
    @table ||= YAML.load_file(Rails.root.join('config/gtfs_discord_texts.yml')).freeze
  end
end
