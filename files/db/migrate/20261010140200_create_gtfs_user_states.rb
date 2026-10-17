# frozen_string_literal: true

# Review A5/K4: matcher state per user (backfill progress, last daily run)
# lives in its own table instead of users.settings, so saving the settings
# page can never overwrite it (and the jobs never overwrite the settings).
class CreateGtfsUserStates < ActiveRecord::Migration[8.1]
  # Review H4: never queue for a lock or run long (see docs/gtfs-deploy.md).
  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '5min'")
    super
  end

  def up
    create_table :gtfs_user_states do |t|
      t.references :user, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.jsonb :backfill, null: false, default: {}
      t.jsonb :last_match, null: false, default: {}
      t.timestamps
    end

    # the backfill state of 91805a3 was kept in users.settings['gtfs_backfill']
    execute <<~SQL.squish
      INSERT INTO gtfs_user_states (user_id, backfill, created_at, updated_at)
      SELECT id, settings->'gtfs_backfill', now(), now() FROM users
       WHERE settings ? 'gtfs_backfill' AND jsonb_typeof(settings->'gtfs_backfill') = 'object'
    SQL
    execute "UPDATE users SET settings = settings - 'gtfs_backfill' WHERE settings ? 'gtfs_backfill'"
  end

  def down
    drop_table :gtfs_user_states
  end
end
