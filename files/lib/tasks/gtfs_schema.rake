# frozen_string_literal: true

# Fresh databases (a new Docker install, a new LXC install): on an empty
# database Rails 8.1 `db:migrate` / `db:prepare` loads db/schema.rb and
# records every migration up to its version as run. Upstream's schema.rb has
# none of our tables, so our migrations older than it would never run (found
# on the first Docker test, 2026-10-20: no gtfs_feeds table). Right after a
# schema load our migrations it recorded are forgotten again, so the same run
# executes them in order, before any newer migration that builds on their
# tables. A database already left that way is repaired after db:migrate. On
# an existing database (the running LXC install, a Docker upgrade) this does
# nothing.
module GtfsSchemaRepair
  # Every custom migration (manifest.json custom_files, db/migrate/);
  # restore_custom.py export refuses to build an image when one is missing here.
  VERSIONS = %w[
    20261010115959 20261010120100 20261010130000 20261010140000 20261010140100
    20261010140200 20261010160000 20261010170000 20261010170100 20261011060000
    20261011130000 20261020101959 20261020121959 20261020153000 20261021090000
    20261021100000 20261021110000
  ].freeze

  # ActiveRecord::Tasks::DatabaseTasks.load_schema, then forget_skipped
  module LoadSchema
    def load_schema(db_config, ...)
      super(db_config, ...).tap do
        next unless db_config.name == 'primary'

        skipped = migration_connection_pool.with_connection { |connection| GtfsSchemaRepair.forget_skipped(connection) }
        puts "[gtfs] schema load: #{skipped.size} custom migration(s) left to run" if skipped.any?
      end
    end
  end

  # After db:migrate: a database whose schema was loaded without LoadSchema.
  def self.call
    skipped = forget_skipped(ActiveRecord::Base.connection)
    return if skipped.empty?

    puts "[gtfs] fresh database: the schema load recorded #{skipped.size} custom migration(s) " \
         'without running them; running them now'
    ActiveRecord::Tasks::DatabaseTasks.migrate
  end

  # Our migrations up to db/schema.rb's version that are recorded while our
  # first table is missing: removed from schema_migrations and returned.
  def self.forget_skipped(connection)
    return [] if connection.table_exists?(:gtfs_feeds)

    schema = Rails.root.join('db/schema.rb')
    schema_version = schema.file? && schema.read[/define\(version: ([\d_]+)\)/, 1]&.delete('_')
    return [] unless schema_version

    recorded = connection.select_values('SELECT version FROM schema_migrations')
    skipped = (recorded & VERSIONS).select { |version| version <= schema_version }
    unless skipped.empty?
      connection.execute("DELETE FROM schema_migrations WHERE version IN (#{skipped.map { connection.quote(_1) }.join(', ')})")
    end
    skipped
  end
end

ActiveRecord::Tasks::DatabaseTasks.singleton_class.prepend(GtfsSchemaRepair::LoadSchema)

namespace :gtfs do
  desc 'Run the custom migrations a fresh schema load recorded without running (done after every db:migrate)'
  task repair_fresh_schema: :environment do
    GtfsSchemaRepair.call
  end
end

Rake::Task['db:migrate'].enhance { GtfsSchemaRepair.call } if Rake::Task.task_defined?('db:migrate')
