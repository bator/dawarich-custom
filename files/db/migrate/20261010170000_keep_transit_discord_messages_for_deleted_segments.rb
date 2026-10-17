# frozen_string_literal: true

# Review H3: a ride's Discord message row outlives the ride. The foreign key
# becomes ON DELETE SET NULL (it was CASCADE), so after the segment is
# deleted (rematch, deleted points, privacy zone, deleted user) the row still
# knows the message, and Gtfs::Discord::MessageCleanupJob edits it to a
# neutral "deleted" text without image or buttons (tombstoned_at). hidden_at
# marks a message replaced while its ride is hidden (privacy zone).
# Only the GTFS tables change; `points` is not touched.
class KeepTransitDiscordMessagesForDeletedSegments < ActiveRecord::Migration[8.1]
  # Review H4: never queue for a lock or run long (see docs/gtfs-deploy.md).
  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '5min'")
    super
  end

  def up
    remove_foreign_key :transit_segment_discord_messages, :transit_segments
    add_foreign_key :transit_segment_discord_messages, :transit_segments, on_delete: :nullify
    change_column_null :transit_segment_discord_messages, :transit_segment_id, true
    add_column :transit_segment_discord_messages, :tombstoned_at, :datetime
    add_column :transit_segment_discord_messages, :hidden_at, :datetime
    add_index :transit_segment_discord_messages, :id, name: 'idx_transit_discord_messages_to_tombstone',
                                                     where: 'transit_segment_id IS NULL AND tombstoned_at IS NULL'
  end

  def down
    execute 'DELETE FROM transit_segment_discord_messages WHERE transit_segment_id IS NULL'
    remove_index :transit_segment_discord_messages, name: 'idx_transit_discord_messages_to_tombstone'
    remove_column :transit_segment_discord_messages, :hidden_at
    remove_column :transit_segment_discord_messages, :tombstoned_at
    change_column_null :transit_segment_discord_messages, :transit_segment_id, false
    remove_foreign_key :transit_segment_discord_messages, :transit_segments
    add_foreign_key :transit_segment_discord_messages, :transit_segments, on_delete: :cascade
  end
end
