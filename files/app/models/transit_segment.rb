# frozen_string_literal: true

# A detected public-transit ride (filled by the GTFS matcher, Phase 2).
# Derived data only: it references points but never changes them.
class TransitSegment < ApplicationRecord
  belongs_to :user
  belongs_to :feed, class_name: 'Gtfs::Feed', inverse_of: :transit_segments
  has_many :transit_segment_points, dependent: :delete_all
  has_many :points, through: :transit_segment_points
  # The message row outlives the ride (FK ON DELETE SET NULL): the Discord
  # message is then edited to "deleted" (review H3).
  has_one :discord_message, class_name: 'TransitSegmentDiscordMessage', dependent: :nullify

  enum :status, { auto: 0, confirmed: 1, rejected: 2 }

  ENDPOINT_COLUMNS = %w[transit_segments.boarding_lonlat transit_segments.alighting_lonlat].freeze

  # Spec 9.4: `auto` rides below AUTO_ACCEPT, with an equally good other line
  # (9.9) or another trip of the same line (review K6), or flagged by the
  # scorer (no intermediate stop to check, no stops at the bus stops) are
  # "uncertain"; the UI asks the user to confirm them.
  def uncertain?
    return false unless auto?

    confidence < Gtfs::Config::AUTO_ACCEPT || debug_flag?('ambiguous') || debug_flag?('trip_ambiguous') ||
      Array(debug&.dig('caps')).any?
  end

  # The estimated delay only means something when the trip itself is certain
  # (review K6: a neighbouring trip of the same line could fit as well).
  def delay_reliable?
    !debug_flag?('ambiguous') && !debug_flag?('trip_ambiguous') && debug&.dig('delay_secs').present?
  end

  # Everything that may be shown to the user (Phase 3 API/UI must use this):
  # - only the user's own rides, and only while matching is enabled for them,
  #   from the feeds they selected (review A4);
  # - confirmed rides and rides switched to another trip by the user (still
  #   `auto` until approved) always, other auto rides at or above
  #   gtfs_min_confidence, rejected rides never;
  # - only rides that still have points (review M1: the points were deleted);
  # - never a ride that starts or ends in one of the user's privacy zones,
  #   also if the zone was added later (review M2, gate D).
  #
  # min_confidence overrides the user's threshold (API parameter), but never
  # goes below GTFS_MATCH_DROP_BELOW.
  def self.visible_for(user, zones: Users::PrivacyZones.new(user).call, min_confidence: nil)
    settings = Gtfs::UserSettings.new(user)
    threshold = min_confidence.nil? ? settings.min_confidence : min_confidence.to_f.clamp(Gtfs::Config::DROP_BELOW, 1.0)
    reviewable_for(user, zones:).where.not(status: :rejected)
                                .where('transit_segments.status = ? OR transit_segments.confidence >= ? OR ' \
                                       "(transit_segments.debug->>'chosen_by_user') = 'true'",
                                       statuses[:confirmed], threshold)
  end

  # What the user may act on (confirm/reject/undo, Phase 3): visible_for
  # without the status and confidence filters, so a rejected or low ride can
  # still be found again by id. Same privacy rules.
  def self.reviewable_for(user, zones: Users::PrivacyZones.new(user).call)
    settings = Gtfs::UserSettings.new(user)
    return none unless settings.enabled?

    scope = where(user:).where(TransitSegmentPoint.where('transit_segment_points.transit_segment_id = ' \
                                                         'transit_segments.id').arel.exists)
    scope = scope.where(feed_id: Gtfs::Feed.where(key: settings.feed_keys).select(:id)) if settings.feed_keys
    zones.empty? ? scope : scope.where.not(zone_condition(zones))
  end

  # Spec 12.2 vehicle filter: GTFS route_type (basic and extended) -> mode.
  def self.mode_for(route_type)
    case route_type
    when 109, 300..399 then 'suburban' # HÉV (before the rail range)
    when 0, 900..906 then 'tram'
    when 1, 401..405, 500..599 then 'metro'
    when 2, 100..117 then 'rail'
    when 4, 1000..1099, 1200 then 'ferry'
    when 3, 11, 700..799, 800, 200..299 then 'bus'
    else 'other'
    end
  end

  def mode
    self.class.mode_for(route_type)
  end

  # SQL condition: one of `columns` lies in one of the zones ([{ lon:, lat:,
  # radius: }]) or is unknown (NULL counts as inside: fail closed).
  def self.zone_condition(zones, columns: ENDPOINT_COLUMNS)
    parts = columns.flat_map do |column|
      ["#{column} IS NULL"] + zones.map do |zone|
        sanitize_sql_array(["ST_DWithin(#{column}, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?)",
                            zone[:lon].to_f, zone[:lat].to_f, zone[:radius].to_f])
      end
    end
    "(#{parts.join(' OR ')})"
  end

  validates :started_at, :ended_at, :feed_version, presence: true
  validates :confidence, presence: true, numericality: { in: 0.0..1.0 }
  validate :ended_after_started

  # Switched to another trip by the user ("Másik járat"): stays `auto`
  # (waiting for approval) but is the user's choice, so rematching keeps it.
  def user_chosen?
    debug_flag?('chosen_by_user')
  end

  # Somebody decided about it (approved, rejected or switched the trip).
  def reviewed?
    !auto? || user_chosen?
  end

  private

  def debug_flag?(key)
    debug&.dig(key) == true
  end

  def ended_after_started
    return if started_at.blank? || ended_at.blank?

    errors.add(:ended_at, 'must not be before started_at') if ended_at < started_at
  end
end
