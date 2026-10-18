# frozen_string_literal: true

# Writes a ride's timetable line onto the target user as points: evenly along the line
# (TrackPick::RideLine, privacy zones already clipped), timestamps interpolated by distance
# between boarding (started_at) and alighting (ended_at), at most one point per second.
# INSERT only, like TrackPick::Copier: a second where the target already has a point is
# skipped. Marked with tracker_id 'track-pick-gtfs' and raw_data.track_pick (there is no
# source point, so no track_pick_copies row).
class TrackPick::GtfsPoints
  TRACKER_ID = 'track-pick-gtfs'
  SPACING_M = 10.0 # densest spacing; long rides get one point per second instead
  EARTH_RADIUS_M = 6_371_000.0

  def initialize(date, segment, target_user = TrackPick::Config.target_user)
    @date = date
    @segment = segment
    @target = target_user
  end

  def usable?
    TrackPick::RideLine::USABLE.include?(line.line_source) && samples.any?
  end

  # number of points that would be / were inserted
  def call(dry_run: false)
    return 0 unless usable?

    conn = ActiveRecord::Base.connection
    values = samples.map { |lon, lat, ts| "(#{lon.to_f}, #{lat.to_f}, #{ts.to_i})" }.join(', ')
    candidates = <<~SQL
      SELECT v.lon, v.lat, v.ts
      FROM (VALUES #{values}) AS v(lon, lat, ts)
      WHERE NOT EXISTS (SELECT 1 FROM points t WHERE t.user_id = #{@target.id.to_i} AND t.timestamp = v.ts
                        AND t.anomaly IS NOT TRUE)
    SQL
    return conn.select_value("SELECT count(*) FROM (#{candidates}) c").to_i if dry_run

    ActiveRecord::Base.transaction do
      conn.execute("SELECT pg_advisory_xact_lock(#{720_161_016}, #{@target.id.to_i})") # same lock as Copier
      inserted = conn.select_value(<<~SQL).to_i
        WITH ins AS (
          INSERT INTO points (lonlat, timestamp, user_id, tracker_id, raw_data, created_at, updated_at)
          SELECT ST_SetSRID(ST_MakePoint(c.lon, c.lat), 4326)::geography, c.ts, #{@target.id.to_i},
                 #{conn.quote(TRACKER_ID)},
                 jsonb_build_object('track_pick', jsonb_build_object('gtfs_segment_id', #{@segment.id.to_i},
                   'line_source', #{conn.quote(line.line_source)}, 'date', #{conn.quote(@date.iso8601)})),
                 now(), now()
          FROM (#{candidates}) c
          ON CONFLICT DO NOTHING
          RETURNING 1
        )
        SELECT count(*) FROM ins
      SQL
      User.update_counters(@target.id, points_count: inserted) if inserted.positive?
      inserted
    end
  end

  def line
    @line ||= TrackPick::RideLine.new(@segment).call
  end

  # [[lon, lat, ts], ...] along the visible runs, distance-timed over the whole line
  def samples
    @samples ||= begin
      runs = line.line.select { |r| r.size >= 2 }
      flat = runs.flatten(1)
      total = flat.each_cons(2).sum { |a, b| dist(a, b) }
      duration = @segment.ended_at.to_i - @segment.started_at.to_i
      if total <= 0 || duration <= 0
        []
      else
        step = [SPACING_M, total / duration].max
        out = []
        travelled = 0.0
        next_at = 0.0
        flat.each_cons(2).with_index do |(a, b), i|
          seg = dist(a, b)
          gap = runs_boundary?(runs, i) # a jump between two clipped runs: time passes, no points
          while !gap && seg.positive? && next_at <= travelled + seg
            t = (next_at - travelled) / seg
            ts = @segment.started_at.to_i + (duration * (next_at / total)).round
            out << [a[0] + ((b[0] - a[0]) * t), a[1] + ((b[1] - a[1]) * t), ts] unless out.last && out.last[2] >= ts
            next_at += step
          end
          travelled += seg
          next_at = travelled if gap && next_at < travelled
        end
        out
      end
    end
  end

  private

  # true when edge i of the flattened runs connects the last point of one run to the next run
  def runs_boundary?(runs, index)
    @ends ||= runs.map(&:size).inject([]) { |acc, n| acc << ((acc.last || 0) + n) }.map { |e| e - 1 }
    @ends[0...-1].include?(index)
  end

  def dist((lon1, lat1), (lon2, lat2))
    rad = Math::PI / 180
    dlat = (lat2 - lat1) * rad
    dlon = (lon2 - lon1) * rad
    a = (Math.sin(dlat / 2)**2) + (Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * (Math.sin(dlon / 2)**2))
    2 * EARTH_RADIUS_M * Math.asin(Math.sqrt(a))
  end
end
