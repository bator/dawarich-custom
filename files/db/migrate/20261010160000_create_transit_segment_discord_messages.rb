# frozen_string_literal: true

# Discord message of a ride (Phase 3 approve/reject buttons). The row is
# created before posting (claim), so two jobs never post the same ride; it
# goes away with the segment.
class CreateTransitSegmentDiscordMessages < ActiveRecord::Migration[8.1]
  # Review H4: never queue for a lock or run long (see docs/gtfs-deploy.md).
  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '5min'")
    super
  end

  def change
    create_table :transit_segment_discord_messages do |t|
      t.references :transit_segment, null: false, index: { unique: true },
                                     foreign_key: { on_delete: :cascade }
      t.string :channel_id, null: false
      t.string :message_id
      t.string :last_status
      t.string :reviewed_by
      t.timestamps
    end
    add_index :transit_segment_discord_messages, %i[channel_id message_id], unique: true,
                                                 name: 'idx_transit_discord_messages_channel_message'
  end
end
