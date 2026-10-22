# frozen_string_literal: true

# The stretches of a user's tracks the map leaves out (docs/atlas.md, "Only
# the snapped line"): where the walking legs layer draws a
# snapped walk (source valhalla or mixed) or the transit layer draws a ride,
# the Tracks tiles cut the raw GPS line under it (Tracks::VectorTileQuery
# hide_ranges_sql), so the map shows one line there, the snapped one.
#
# The same visibility as the layers themselves (Gtfs::WalkLegQuery,
# Gtfs::SegmentQuery: opt-in, exclusion, display threshold, feed selection,
# privacy zones): what a layer does not show is never cut. A walk the snap
# could not match (source raw) is not cut either; the layer draws it as
# recorded, the track line stays.
class Gtfs::TrackCutouts
  KINDS = %w[walks rides].freeze
  SNAPPED_SOURCES = %w[valhalla mixed].freeze

  # "walks,rides" (the tile parameter) => the known kinds, in KINDS order
  def self.parse(value) = KINDS & value.to_s.split(',').map(&:strip)

  attr_reader :kinds

  # start_at / end_at: the tile request's range (Unix seconds)
  def initialize(user, kinds, start_at:, end_at:)
    @user = user
    @kinds = kinds
    @start_at = start_at.to_i
    @end_at = end_at.to_i
  end

  # SQL of one int8multirange of the covered seconds (each window [start,
  # end], overlaps merged), or nil when nothing is to be cut
  def ranges_sql
    windows = scopes.map { |scope| windows_sql(scope) }
    return if windows.empty?

    "SELECT range_agg(int8range(w.started_at::bigint, w.ended_at::bigint, '[]')) " \
      "FROM (#{windows.join(' UNION ALL ')}) AS w"
  end

  # ETag material: changes whenever the cut can change (legs rewritten or
  # deleted, rides matched or reviewed, settings, privacy zones). Plain
  # per-user latest change and count: the visibility conditions would cost
  # more than the tile.
  def epoch
    [(changes(TransitWalkLeg) if @kinds.include?('walks')), (changes(TransitSegment) if @kinds.include?('rides')),
     @user.updated_at.to_i, Digest::MD5.hexdigest(zones.to_json)].compact
  end

  private

  def scopes
    @scopes ||= [(walk_scope if @kinds.include?('walks')), (ride_scope if @kinds.include?('rides'))].compact
  end

  def walk_scope = Gtfs::WalkLegQuery.new(@user, zones:).scope.where(source: SNAPPED_SOURCES)

  def ride_scope = Gtfs::SegmentQuery.new(@user, zones:).scope

  def zones = @zones ||= Users::PrivacyZones.new(@user).call

  def changes(model)
    model.where(user_id: @user.id).pick(Arel.sql('extract(epoch from max(updated_at))::bigint'), Arel.sql('count(*)'))
  end

  def windows_sql(scope)
    scope.except(:order, :includes, :select)
         .where(started_at: ..@end_at, ended_at: @start_at..)
         .select(:started_at, :ended_at).to_sql
  end
end
