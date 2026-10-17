# frozen_string_literal: true

# Walking legs next to transit rides, snapped with Valhalla (docs/gtfs-walk.md).
# Derived data: no foreign key, trigger or lock on points (see
# docs/gtfs-deploy.md). point_ids / ride_ids are plain arrays, checked by
# Gtfs::Walk::Cleanup (deleted points, rejected or deleted rides). One leg per
# user and start (unique, review M2).
class CreateTransitWalkLegs < ActiveRecord::Migration[8.1]
  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '5min'")
    super
  end

  def change
    create_table :transit_walk_legs do |t|
      t.references :user, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.bigint  :started_at, null: false
      t.bigint  :ended_at, null: false
      t.integer :point_count, null: false, default: 0
      t.bigint  :point_ids, array: true, null: false, default: []
      t.bigint  :ride_ids, array: true, null: false, default: []
      t.float   :raw_distance_m
      t.float   :distance_m
      t.string  :source, null: false
      t.jsonb   :parts, null: false, default: []
      t.jsonb   :stats
      t.timestamps
    end
    add_index :transit_walk_legs, %i[user_id started_at], unique: true
  end
end
