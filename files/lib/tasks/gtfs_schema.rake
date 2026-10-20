# frozen_string_literal: true

# Fresh databases (a new Docker install, a new LXC install): on an empty
# database Rails 8.1 `db:migrate` loads db/schema.rb and records every
# migration up to its version as run. Upstream's schema.rb has none of our
# tables, so our migrations older than it would never run (found on the first
# Docker test, 2026-10-20: no gtfs_feeds table). After db:migrate: if our
# first table is missing but our migrations up to the schema version are
# recorded, forget them and migrate again. On an existing database (the
# running LXC install, a Docker upgrade) this does nothing.
module GtfsSchemaRepair
  # Every custom migration (manifest.json custom_files, db/migrate/);
  # restore_custom.py export refuses to build an image when one is missing here.
  VERSIONS = %w[
    20261010115959 20261010120100 20261010130000 20261010140000 20261010140100
    20261010140200 20261010160000 20261010170000 20261010170100 20261011060000
    20261011130000 20261020101959 20261020121959 20261020153000 20261021090000
  ].freeze

  def self.call
    connection = ActiveRecord::Base.connection
    return if connection.table_exists?(:gtfs_feeds)

    schema = Rails.root.join('db/schema.rb')
    schema_version = schema.file? && schema.read[/define\(version: ([\d_]+)\)/, 1]&.delete('_')
    return unless schema_version

    recorded = connection.select_values('SELECT version FROM schema_migrations')
    skipped = (recorded & VERSIONS).select { |version| version <= schema_version }
    return if skipped.empty?

    puts "[gtfs] fresh database: the schema load recorded #{skipped.size} custom migration(s) " \
         "up to #{schema_version} without running them; running them now"
    connection.execute("DELETE FROM schema_migrations WHERE version IN (#{skipped.map { connection.quote(_1) }.join(', ')})")
    ActiveRecord::Tasks::DatabaseTasks.migrate
  end
end

namespace :gtfs do
  desc 'Run the custom migrations a fresh schema load recorded without running (done after every db:migrate)'
  task repair_fresh_schema: :environment do
    GtfsSchemaRepair.call
  end
end

Rake::Task['db:migrate'].enhance { GtfsSchemaRepair.call } if Rake::Task.task_defined?('db:migrate')
