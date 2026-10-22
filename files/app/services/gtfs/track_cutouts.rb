# frozen_string_literal: true

# The stretches of a user's tracks the map leaves out (docs/atlas.md, "Only
# the snapped line"): where the walking legs layer draws a walk or the
# transit layer draws a ride, the Tracks tiles cut the raw GPS line under it
# (Tracks::VectorTileQuery hide_ranges_sql), so the map shows one line there,
# the walk's or the ride's. Everywhere else the raw line stays and joins the
# drawn ones.
#
# Both are cut for all of their time: the walking legs layer draws a walk
# from its first to its last fix, the snapped parts and, dashed, what lies
# between them along the recorded fixes (Api::TransitWalkLegSerializer#joints;
# Bator, 2026-10-22: the stretches between the snapped parts dashed, not as
# the raw track line), and a ride's timetable line covers all of the ride.
#
# Exactly what the layers draw for the map's range: the same queries
# (Gtfs::WalkLegQuery, Gtfs::SegmentQuery: opt-in, exclusion, display
# threshold, feed selection, privacy zones), the same range rule (start within
# the range) and the same cap (the newest 500 of each, as the map endpoints
# answer): what a layer does not show is never cut, nor a walk without a
# drawn line.
class Gtfs::TrackCutouts
  KINDS = %w[walks rides].freeze
  # Longer ranges are not cut: every track under a cut stretch is rebuilt from
  # its points, which over months costs seconds a tile.
  MAX_DAYS = 93

  # "walks,rides" (the tile parameter) => the known kinds, in KINDS order
  def self.parse(value) = KINDS & value.to_s.split(',').map(&:strip)

  # A range the cut is worth computing for (start_at / end_at: Unix seconds)
  def self.range_ok?(start_at, end_at) = end_at.to_i - start_at.to_i <= MAX_DAYS.days.to_i

  attr_reader :kinds

  # start_at / end_at: the tile request's range (Unix seconds)
  def initialize(user, kinds, start_at:, end_at:)
    @user = user
    @kinds = kinds
    @start_at = start_at.to_i
    @end_at = end_at.to_i
  end

  # SQL of one int8multirange of the covered seconds (a segment [t1, t2) is
  # cut when it lies inside), or nil when nothing is to be cut
  def ranges_sql
    parts = []
    if walks?
      shown = walk_query.scope.limit(Gtfs::WalkLegQuery::MAX_MAP_LEGS).select(:id)
      parts << TransitWalkLeg.where(id: shown).where.not(drawn: nil)
                             .select(Arel.sql("int8range(transit_walk_legs.started_at, " \
                                              "transit_walk_legs.ended_at, '[]') AS r")).to_sql
    end
    if @kinds.include?('rides')
      shown = ride_query.scope.except(:includes).limit(Gtfs::SegmentQuery::MAX_MAP_SEGMENTS).select(:id)
      parts << TransitSegment.where(id: shown)
                             .select(Arel.sql("int8range(transit_segments.started_at::bigint, " \
                                              "transit_segments.ended_at::bigint, '[]') AS r")).to_sql
    end
    return if parts.empty?

    "SELECT range_agg(w.r) FROM (#{parts.join(' UNION ALL ')}) AS w"
  end

  # ETag material: changes whenever the cut can change (legs rewritten or
  # deleted, rides matched or reviewed, settings, privacy zones). Plain
  # per-user latest change and count: the visibility conditions would cost
  # more than the tile.
  def epoch
    [(changes(TransitWalkLeg) if walks?), (changes(TransitSegment) if @kinds.include?('rides')),
     @user.updated_at.to_i, Digest::MD5.hexdigest(zones.to_json)].compact
  end

  private

  def walks? = @kinds.include?('walks')

  def walk_query = Gtfs::WalkLegQuery.new(@user, range_params, zones)

  def ride_query = Gtfs::SegmentQuery.new(@user, range_params, zones)

  def range_params = { start_at: @start_at, end_at: @end_at }

  def zones = @zones ||= Users::PrivacyZones.new(@user).call

  def changes(model)
    model.where(user_id: @user.id).pick(Arel.sql('extract(epoch from max(updated_at))::bigint'), Arel.sql('count(*)'))
  end
end
