# frozen_string_literal: true

# The trips a user's frequent routes are built from, or one track to snap:
# the raw points of the track (not its stored, possibly snapped geometry),
# real fixes only (Corridors::Config.synthetic? drops generated points), with
# bad fixes and the standing-still ends removed, in local metres.
class Corridors::TripSource
  Trip = Struct.new(:track_id, :mode, :started_at, :ended_at, :xy, keyword_init: true)

  ACCURACY_MAX_M = 50
  MAX_SPEED = { 'walking' => 4.0, 'running' => 7.0, 'cycling' => 15.0 }.freeze # m/s, faster jumps are dropped
  MIN_REAL_SHARE = 0.8 # of a track's points, or the track is left out
  STILL_SECONDS = 60   # an end is "standing still" while the fix 60 s later is within STILL_M
  STILL_M = 25.0
  MIN_POINTS = 10
  MIN_LENGTH_M = 300.0

  attr_reader :frame

  def initialize(user, frame: nil)
    @user = user
    @frame = frame || default_frame
  end

  # The user's tracks of the configured modes and period.
  def trips(modes: Corridors::Config.modes, since: Corridors::Config.days.days.ago)
    ids = @user.tracks.where(dominant_mode: modes).where(start_at: since..).pluck(:id)
    load(ids)
  end

  def trip(track) = load([track.id]).first

  private

  def load(ids)
    return [] if ids.empty?

    tracks = Track.where(id: ids).pluck(:id, :dominant_mode, :start_at, :end_at).to_h { |id, *rest| [id, rest] }
    rows = Point.connection.select_rows(<<~SQL.squish)
      SELECT track_id, ST_X(lonlat::geometry), ST_Y(lonlat::geometry), timestamp, accuracy, tracker_id
      FROM points
      WHERE track_id IN (#{ids.map(&:to_i).join(',')}) AND lonlat IS NOT NULL
      ORDER BY track_id, timestamp
    SQL
    rows.group_by(&:first).filter_map do |track_id, points|
      mode, started_at, ended_at = tracks[track_id]
      real = points.reject { |p| Corridors::Config.synthetic?(p[5]) }
      next if real.size < MIN_POINTS || real.size < points.size * MIN_REAL_SHARE

      fixes = clean(real, mode)
      fixes = trim_still_ends(fixes)
      next if fixes.size < MIN_POINTS

      xy = fixes.map { |f| @frame.xy(f[0], f[1]) }
      next if Corridors::Geometry.length(xy) < MIN_LENGTH_M

      Trip.new(track_id:, mode:, started_at:, ended_at:, xy:)
    end
  end

  # [[lon, lat, timestamp], ...] without inaccurate fixes, duplicates and impossible jumps
  def clean(points, mode)
    vmax = MAX_SPEED.fetch(mode, 70.0)
    out = []
    points.each do |_, lon, lat, ts, accuracy, _|
      next if accuracy && accuracy.to_f > ACCURACY_MAX_M

      fix = [lon.to_f, lat.to_f, ts.to_i]
      if (last = out.last)
        d = metres(last, fix)
        next if d < 1.0
        next if d / [fix[2] - last[2], 1].max > vmax
      end
      out << fix
    end
    out
  end

  # GPS keeps moving while you stand still (indoors before leaving, at the
  # door on arrival): that cloud would put a loop at the route's ends.
  def trim_still_ends(fixes)
    first = (0...fixes.size).find { |i| !still?(fixes, i, +1) } || 0
    last = (fixes.size - 1).downto(0).find { |i| !still?(fixes, i, -1) } || (fixes.size - 1)
    first < last ? fixes[first..last] : fixes
  end

  def still?(fixes, i, direction)
    j = i
    j += direction while j.between?(0, fixes.size - 1) && (fixes[j][2] - fixes[i][2]).abs < STILL_SECONDS
    return false unless j.between?(0, fixes.size - 1)

    metres(fixes[i], fixes[j]) < STILL_M
  end

  def metres(a, b)
    kx = Math.cos(a[1] * Math::PI / 180) * 111_320
    Math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * 110_540)
  end

  # Around the user's last point (a frequent route is near home).
  def default_frame
    lon, lat = Point.where(user_id: @user.id).where.not(lonlat: nil).order(timestamp: :desc)
                    .pick(Arel.sql('ST_X(lonlat::geometry)'), Arel.sql('ST_Y(lonlat::geometry)'))
    Corridors::Geometry::Frame.new(lon.to_f, lat.to_f)
  end
end
