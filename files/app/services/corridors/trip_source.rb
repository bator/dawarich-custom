# frozen_string_literal: true

# The trips a user's frequent routes are built from, or the tracks to snap:
# the raw points of the track (not its stored, possibly snapped geometry),
# real fixes only (Corridors::Config.synthetic? drops generated points), with
# bad fixes and the standing-still ends removed, as lon/lat. Nothing here
# hangs on a shared frame: a route or a track gets local metres of its own for
# the exact work (Trip#in_frame), and lengths are measured around each trip.
class Corridors::TripSource
  # xy: local metres, set by #in_frame
  Trip = Struct.new(:track_id, :mode, :started_at, :ended_at, :lonlat, :xy, keyword_init: true) do
    # the same trip in local metres around a centre
    def in_frame(frame) = dup.tap { |t| t.xy = lonlat.map { |lon, lat| frame.xy(lon, lat) } }

    def reversed = dup.tap { |t| t.lonlat = lonlat.reverse; t.xy = xy&.reverse }

    def length_m = Corridors::Geometry.length(in_frame(Corridors::Geometry::Frame.new(*lonlat.first)).xy)
  end

  ACCURACY_MAX_M = 50
  MAX_SPEED = { 'walking' => 4.0, 'running' => 7.0, 'cycling' => 15.0 }.freeze # m/s, faster jumps are dropped
  MIN_REAL_SHARE = 0.8 # of a track's points, or the track is left out
  STILL_SECONDS = 60   # an end is "standing still" while the fix 60 s later is within STILL_M
  STILL_M = 25.0
  MIN_POINTS = 10
  MIN_LENGTH_M = 300.0

  def initialize(user)
    @user = user
  end

  # The user's tracks of the configured modes and period.
  def trips(modes: Corridors::Config.modes, since: Corridors::Config.days.days.ago)
    ids = @user.tracks.where(dominant_mode: modes).where(start_at: since..).pluck(:id)
    load(ids)
  end

  # {track_id => Trip} of these tracks, in one query (a track without enough
  # real fixes is missing).
  def trips_for(track_ids) = load(track_ids).index_by(&:track_id)

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
    loaded = rows.group_by(&:first).filter_map do |track_id, points|
      mode, started_at, ended_at = tracks[track_id]
      real = points.reject { |p| Corridors::Config.synthetic?(p[5]) }
      next if real.size < MIN_POINTS || real.size < points.size * MIN_REAL_SHARE

      fixes = trim_still_ends(clean(real, mode))
      next if fixes.size < MIN_POINTS

      Trip.new(track_id:, mode:, started_at:, ended_at:, lonlat: fixes.map { |lon, lat, _| [lon, lat] })
    end
    loaded.select { |t| t.length_m >= MIN_LENGTH_M }
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
end
