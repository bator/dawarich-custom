# frozen_string_literal: true

# /transit/discord (admins): settings of the Discord bot (ride approvals and
# track_pick) edited on the page instead of /opt/dawarich/gtfs.env. One row;
# a key missing from `values` falls back to the environment. The bot token is
# in its own column, encrypted (ActiveRecord encryption), and never shown.
class CreateGtfsDiscordSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :gtfs_discord_settings do |t|
      t.boolean :singleton, null: false, default: true
      t.jsonb :values, null: false, default: {}
      t.text :bot_token
      t.references :updated_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :gtfs_discord_settings, :singleton, unique: true
  end
end
