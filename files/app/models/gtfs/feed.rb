# frozen_string_literal: true

# One GTFS source (e.g. "budapest", "volanbusz", "mav") with its download and
# import state. All timetable rows are stored per (feed, version); only
# `active_version` is visible to readers.
class Gtfs::Feed < ApplicationRecord
  EXPIRY_WARNING_DAYS = 14

  enum :status, { idle: 0, importing: 1, failed: 2 }

  # Data rows are removed by the ON DELETE CASCADE foreign keys (millions of
  # rows; loading them into Ruby for destroy callbacks would not be feasible).
  with_options inverse_of: :feed, dependent: nil do
    has_many :stops,        class_name: 'Gtfs::Stop'
    has_many :routes,       class_name: 'Gtfs::Route'
    has_many :trips,        class_name: 'Gtfs::Trip'
    has_many :stop_times,   class_name: 'Gtfs::StopTime'
    has_many :service_days, class_name: 'Gtfs::ServiceDay'
    has_many :shapes,       class_name: 'Gtfs::Shape'
    has_many :frequencies,  class_name: 'Gtfs::Frequency'
  end
  has_many :transit_segments, dependent: :restrict_with_exception, inverse_of: :feed

  validates :key, presence: true, uniqueness: true, format: { with: /\A[a-z0-9_-]+\z/ }
  validates :name, :timezone, presence: true
  validate :timezone_known

  scope :enabled, -> { where(enabled: true) }

  def imported?
    active_version.positive?
  end

  def expired?(on: Date.current)
    valid_until.present? && valid_until < on
  end

  def expiring_soon?(on: Date.current, days: EXPIRY_WARNING_DAYS)
    valid_until.present? && !expired?(on:) && valid_until <= on + days
  end

  # Usable for matching on `date`: imported and inside the validity window.
  def valid_on?(date)
    return false unless imported?
    return false if valid_from.present? && date < valid_from
    return false if valid_until.present? && date > valid_until

    true
  end

  def time_zone
    ActiveSupport::TimeZone[timezone]
  end

  # Deletes a feed with all its timetable rows. The rows are removed in
  # batches first (Gtfs::VersionPurger) so that dropping a Budapest-sized feed
  # is not one multi-million-row cascade DELETE in a single transaction.
  # Raises like #destroy if transit segments still reference the feed.
  def purge_and_destroy!
    raise ActiveRecord::DeleteRestrictionError, :transit_segments if transit_segments.exists?

    Gtfs::VersionPurger.versions(id).each { |version| Gtfs::VersionPurger.purge!(id, version) }
    destroy!
  end

  def advisory_lock_name
    "gtfs_feed_import_#{id}"
  end

  private

  def timezone_known
    errors.add(:timezone, 'is not a known time zone') if timezone.present? && time_zone.nil?
  end
end
