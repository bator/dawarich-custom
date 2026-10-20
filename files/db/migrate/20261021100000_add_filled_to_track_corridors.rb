# frozen_string_literal: true

# Frequent routes (docs/corridors.md): the stretches of a route's line that
# were routed through a gap (Corridors::GapFiller) instead of the median.
class AddFilledToTrackCorridors < ActiveRecord::Migration[8.1]
  def exec_migration(connection, direction)
    connection.execute("SET LOCAL lock_timeout = '5s'")
    connection.execute("SET LOCAL statement_timeout = '5min'")
    super
  end

  def change
    add_column :track_corridors, :filled, :jsonb, null: false, default: [] # [[from_m, to_m], ...] along the line
  end
end
