# frozen_string_literal: true

# Namespace for static GTFS timetable data (see docs/gtfs.md).
module Gtfs
  def self.table_name_prefix
    'gtfs_'
  end

  def self.enabled?
    ENV.fetch('GTFS_ENABLED', 'false').to_s == 'true'
  end

  # Downloads and the sorted stop_times export go here (spec: tmp/gtfs/), not
  # to the container's /tmp. GTFS_TMP_DIR can point to a bigger volume.
  def self.tmp_dir
    dir = ENV['GTFS_TMP_DIR'].presence || Rails.root.join('tmp/gtfs').to_s
    FileUtils.mkdir_p(dir)
    dir
  end

  # Removes files left behind by killed imports/downloads.
  def self.cleanup_tmp_dir!(older_than: 1.day)
    Dir.glob(File.join(tmp_dir, 'gtfs-*')).count do |path|
      next false unless File.file?(path) && File.mtime(path) < older_than.ago

      File.delete(path)
      true
    end
  end
end
