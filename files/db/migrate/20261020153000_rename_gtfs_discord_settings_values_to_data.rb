# frozen_string_literal: true

# The settings column is `data` in Gtfs::DiscordSetting and the controller,
# but 20261020121959 created it as `values`: the first save on /transit/discord
# created the row and failed (NoMethodError `data`), and from then on every
# reader of the row failed too (bot settings check, Config, the page).
# Renaming the column makes the table match the code. Reversible.
class RenameGtfsDiscordSettingsValuesToData < ActiveRecord::Migration[8.1]
  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    super
  end

  def change
    rename_column :gtfs_discord_settings, :values, :data
  end
end
