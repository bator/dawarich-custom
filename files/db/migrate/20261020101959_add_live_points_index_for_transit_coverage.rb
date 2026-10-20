# frozen_string_literal: true

# /transit/coverage reads the (user_id, timestamp) of every live point of the
# period (Gtfs::CoverageReport) and groups them by device (Gtfs::DeviceReports).
# With only index_points_on_user_id_timestamp_lonlat each row is fetched from
# the heap to test import_id; the rows are wide (raw_data), so a 30-day page
# read ~200 MB, 10-16 s with a cold cache. This partial index covers both
# queries (index-only scan) and holds live points only. Built CONCURRENTLY, so
# points keep being written meanwhile; a failed build leaves an INVALID index,
# which the next run drops and rebuilds. Reversible: down drops the index.
class AddLivePointsIndexForTransitCoverage < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX = 'index_points_live_on_user_id_timestamp'

  def up
    remove_index :points, name: INDEX, algorithm: :concurrently if invalid_index?
    add_index :points, %i[user_id timestamp], name: INDEX, where: 'import_id IS NULL',
                                              include: %i[source_id tracker_id],
                                              algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :points, name: INDEX, algorithm: :concurrently, if_exists: true
  end

  private

  def invalid_index?
    select_value(<<~SQL.squish) == false
      SELECT i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = '#{INDEX}'
    SQL
  end
end
