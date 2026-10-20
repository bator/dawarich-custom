# frozen_string_literal: true

# Frequent routes (docs/corridors.md): the robust median line of a route a
# user travelled many times (Corridors::Builder, rebuilt weekly, so ids are
# not stable), and the log of tracks snapped onto one (Corridors::Snapper),
# which keeps the geometry before the snap for `corridors:revert`.
class CreateTrackCorridors < ActiveRecord::Migration[8.1]
  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '5min'")
    super
  end

  def change
    create_table :track_corridors do |t|
      t.references :user, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :mode, null: false
      t.line_string :path, srid: 4326, null: false
      t.float :length_m, null: false
      t.integer :trips, null: false
      t.bigint :track_ids, array: true, null: false, default: []
      t.float :spread_p50
      t.float :spread_p90
      t.jsonb :gaps, null: false, default: [] # [[from_m, to_m], ...] along the line, few real fixes there
      t.timestamps
    end
    add_index :track_corridors, %i[user_id mode]
    add_index :track_corridors, :path, using: :gist

    create_table :track_corridor_snaps do |t|
      t.references :track, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, index: true, foreign_key: { on_delete: :cascade }
      t.bigint :corridor_id # no foreign key: corridors are rebuilt
      t.line_string :original_path, srid: 4326, null: false
      t.float :original_distance
      t.float :original_avg_speed
      t.float :inside_share
      t.datetime :track_updated_at, null: false # a later recalculation of the track makes it differ
      t.timestamps
    end
  end
end
