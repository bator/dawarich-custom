# frozen_string_literal: true

# Copies one day's points of a source user onto the target user.
# INSERT only: never UPDATE or DELETE points. Dedup: a source point is
# skipped when the target already has a point with the same timestamp
# (and ON CONFLICT DO NOTHING for the unique (user_id, timestamp, lonlat)).
# scope: :all, :inside or :outside the fixed inner-city bbox (TrackPick::Comparison::BUDAPEST),
# so "whole day from A, inner city from B" is two copies in one transaction.
class TrackPick::Copier
  SCOPES = %i[all inside outside].freeze

  COLUMNS = %w[accuracy altitude altitude_decimal battery battery_status bssid city connection country
               country_id country_name course course_accuracy geodata lonlat mode ssid topic tracker_id
               trigger velocity vertical_accuracy reverse_geocoded_at].freeze

  def initialize(date, source_user, target_user = TrackPick::Config.target_user, scope: :all)
    raise ArgumentError, "unknown scope #{scope}" unless SCOPES.include?(scope)

    @date = date
    @source = source_user
    @target = target_user
    @scope = scope
  end

  # number of points that would be / were inserted
  def call(dry_run: false)
    return 0 if @source.id == @target.id

    from, to = TrackPick::Config.day_range(@date)
    conn = ActiveRecord::Base.connection
    candidates = <<~SQL
      SELECT DISTINCT ON (s.timestamp) s.*
      FROM points s
      WHERE s.user_id = #{@source.id.to_i} AND s.timestamp >= #{from.to_i} AND s.timestamp < #{to.to_i}
        AND s.lonlat IS NOT NULL#{scope_sql}
        AND NOT EXISTS (SELECT 1 FROM points t WHERE t.user_id = #{@target.id.to_i} AND t.timestamp = s.timestamp)
      ORDER BY s.timestamp, s.id
    SQL
    return conn.select_value("SELECT count(*) FROM (#{candidates}) c").to_i if dry_run

    cols = COLUMNS.join(', ')
    ActiveRecord::Base.transaction do
      conn.execute("SELECT pg_advisory_xact_lock(#{720_161_016}, #{@target.id.to_i})")
      # K1: points + provenance (track_pick_copies) in ONE statement; raw_data marker kept as a second trail
      inserted = conn.select_value(<<~SQL).to_i
        WITH c AS (#{candidates}),
        ins AS (
          INSERT INTO points (#{cols}, timestamp, user_id, raw_data, created_at, updated_at)
          SELECT #{cols}, c.timestamp, #{@target.id.to_i},
                 jsonb_build_object('track_pick', jsonb_build_object('source_user_id', c.user_id,
                   'source_point_id', c.id, 'date', #{conn.quote(@date.iso8601)})),
                 now(), now()
          FROM c
          ON CONFLICT DO NOTHING
          RETURNING id, timestamp
        ),
        prov AS (
          INSERT INTO track_pick_copies (target_point_id, source_point_id, source_user_id, target_user_id, day)
          SELECT ins.id, c.id, c.user_id, #{@target.id.to_i}, #{conn.quote(@date.iso8601)}::date
          FROM ins JOIN c ON c.timestamp = ins.timestamp
          ON CONFLICT DO NOTHING
          RETURNING 1
        )
        SELECT count(*) FROM ins
      SQL
      # K4: keep the users.points_count counter cache in step (users table only, same as Points::Intake)
      User.update_counters(@target.id, points_count: inserted) if inserted.positive?
      inserted
    end
  end

  private

  def scope_sql
    return '' if @scope == :all

    bp = TrackPick::Comparison::BUDAPEST # same inclusive bounds as Comparison.budapest?
    inside = "ST_Y(s.lonlat::geometry) BETWEEN #{bp[:lat].begin.to_f} AND #{bp[:lat].end.to_f} " \
             "AND ST_X(s.lonlat::geometry) BETWEEN #{bp[:lon].begin.to_f} AND #{bp[:lon].end.to_f}"
    @scope == :inside ? "\n        AND (#{inside})" : "\n        AND NOT (#{inside})"
  end
end
