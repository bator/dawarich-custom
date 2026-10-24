# frozen_string_literal: true

# The transport modes users set by hand on track segments, kept apart from
# the segments (TrackModeCorrections). A bulk track rebuild (Dawarich's
# Tracks::ParallelGenerator, run by TrackPick::Hider and AccuracyGate) deletes
# the tracks with their segments and the hand-set modes went with them
# (user 2, 2026-10-24: 45 corrections). From here they are written back onto
# the rebuilt tracks. Derived from user input: down drops the table.
class CreateTrackModeCorrections < ActiveRecord::Migration[8.1]
  def change
    create_table :track_mode_corrections do |t|
      t.bigint :user_id, null: false
      t.datetime :start_at, null: false
      t.datetime :end_at, null: false
      t.string :transportation_mode, null: false
      t.datetime :captured_at, null: false
      t.timestamps
    end
    add_index :track_mode_corrections, %i[user_id start_at end_at], unique: true,
                                                                     name: 'index_track_mode_corrections_on_span'
    add_foreign_key :track_mode_corrections, :users, on_delete: :cascade
  end
end
