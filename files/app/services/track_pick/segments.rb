# frozen_string_literal: true

# The day of a track pick cut into segments, each picked on its own (Bator 2026-11-08:
# "Szegmenseket szeretnék kiválasztani és jóváhagyni, nem az egész napokat. Mivel valahol
# jobb az egyik mint a másik."):
#
# - :ride  one GTFS ride of the day (TrackPick::MapImage.rides: any source user, the same
#          route overlapping in time is one ride), from its earliest start to its latest end;
# - :move  the time between two rides (or before the first / after the last) when some source
#          moved there, trimmed to where it moved. A stay at one place is no segment: there is
#          nothing to choose.
#
# Every segment carries per source user its numbers in that time (points, share of the time
# covered by fixes at most COVER_STEP apart) and a recommendation: the best covered source, or
# the timetable line of a ride when no GPS covers the ride well. A segment not picked keeps the
# target's own points. The list is written to state/segments-<date>.json when the message is
# posted, so a click refers to a segment by its number.
class TrackPick::Segments
  Source = Struct.new(:user, :count, :coverage, :km, keyword_init: true)
  Segment = Struct.new(:index, :kind, :from, :to, :ride, :title, :sources, :gtfs, :recommended,
                       keyword_init: true) do
    def ride_segment = ride&.segment

    def as_json(*)
      { index:, kind: kind.to_s, from:, to:, title:, segment_id: ride_segment&.id, gtfs:, recommended: }
    end
  end

  MAX_SEGMENTS = 8 # one sheet row each; also keeps the select under 25 options
  COVER_STEP = 90 # seconds: a step this short counts as covered time
  MOVE_MIN_M = 400 # a :move segment needs a source this far from where it stood
  MOVE_PAD = 120 # seconds kept before the first and after the last moving fix
  MIN_MOVE_SECS = 180
  GOOD_COVERAGE = 0.7 # a ride whose best GPS covers less is recommended from the timetable line
  MOVING_MPS = 1.0 # a step at least this fast is movement (walking included)
  MOVING_STEP = 300 # seconds: longer steps say nothing about movement

  attr_reader :date

  def initialize(comparison, rides = TrackPick::MapImage.rides(comparison))
    @comparison = comparison
    @date = comparison.date
    @rides = rides
  end

  def call
    @call ||= build.first(MAX_SEGMENTS).each_with_index.map do |seg, i|
      seg.index = i + 1
      seg
    end
  end

  def to_h = { date: date.iso8601, segments: call.map(&:as_json) }

  def self.path(date) = File.join(TrackPick::Config::STATE_DIR, "segments-#{date.iso8601}.json")

  def save!
    FileUtils.mkdir_p(TrackPick::Config::STATE_DIR)
    File.write(self.class.path(date), JSON.pretty_generate(to_h))
  end

  # the saved list of a posted message: [{ 'index' =>, 'kind' =>, 'from' =>, 'to' =>, ... }], or nil
  def self.load(date)
    JSON.parse(File.read(path(date)))['segments']
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end

  private

  def stats = @comparison.call

  def build
    day_from, day_to = TrackPick::Config.day_range(date)
    rides = @rides.map { |r| [ride_span(r), r] }.sort_by { |(from, _), _| from }
    out = []
    cursor = day_from
    rides.each do |(from, to), ride|
      out.concat(moves(cursor, from))
      out << ride_segment(ride, from, to)
      cursor = to
    end
    out.concat(moves(cursor, day_to))
    out.sort_by(&:from)
  end

  # the ride's own time (MapImage pads it with RIDE_MARGIN for the picture)
  def ride_span(ride)
    margin = TrackPick::MapImage::RIDE_MARGIN
    [ride.from + margin, ride.to - margin]
  end

  def ride_segment(ride, from, to)
    seg = ride.segment
    gtfs = TrackPick::GtfsPoints.new(date, seg).usable?
    sources = sources_in(from, to, ride: true)
    best = best_source(sources)
    recommended = if gtfs && (best.nil? || best.coverage < GOOD_COVERAGE)
                    'g'
                  else
                    best&.user&.id&.to_s
                  end
    Segment.new(kind: :ride, from:, to:, ride:, gtfs:, sources:, recommended:,
                title: "#{seg.route_short_name} #{seg.boarding_stop_name} → #{seg.alighting_stop_name}")
  rescue StandardError => e
    Rails.logger.warn("[track_pick] ride segment #{ride.segment.id}: #{e.class}: #{e.message}")
    Segment.new(kind: :ride, from:, to:, ride:, gtfs: false, sources: sources_in(from, to, ride: true), recommended: nil,
                title: "#{ride.segment.route_short_name} #{ride.segment.boarding_stop_name} → " \
                       "#{ride.segment.alighting_stop_name}")
  end

  # the part of [from, to] where some source moved, as one segment (or none)
  def moves(from, to)
    return [] if to - from < MIN_MOVE_SECS

    moving = stats.flat_map { |s| moving_times(s, from, to) }
    return [] if moving.empty?

    a = [moving.min - MOVE_PAD, from].max
    b = [moving.max + MOVE_PAD, to].min
    return [] if b - a < MIN_MOVE_SECS

    sources = sources_in(a, b)
    best = best_source(sources)
    [Segment.new(kind: :move, from: a, to: b, ride: nil, gtfs: false, sources:,
                 recommended: best&.user&.id&.to_s, title: move_title(a, b))]
  end

  # timestamps of the source's fixes in [from, to] that lie MOVE_MIN_M or more from the
  # median position of that time (a stay is a cloud around its median)
  def moving_times(stat, from, to)
    pts = good(stat.user).select { |ts, _| ts >= from && ts < to }
    return [] if pts.size < 3

    lons = pts.map { |_, (lon, _)| lon }.sort
    lats = pts.map { |_, (_, lat)| lat }.sort
    centre = [lons[lons.size / 2], lats[lats.size / 2]]
    far = pts.select { |_, c| dist(c, centre) >= MOVE_MIN_M }
    far.size >= 2 ? [far.first[0], far.last[0]] : []
  end

  # Per source in [from, to]: its good fixes (not flagged, accuracy at most MAX_ACCURACY_M), the
  # share of the moving time they cover (steps at most COVER_STEP apart), and the km they draw.
  # The moving time is when any source moved (a stay counts for nobody: the logger records only
  # while it moves, the phone also while standing); without movement it is the whole segment.
  # On a ride the vehicle moves all the time, underground too: the whole ride counts.
  def sources_in(from, to, ride: false)
    windows = stats.to_h { |s| [s.user.id, good(s.user).select { |ts, _| ts.between?(from, to) }] }
    moving = ride ? [[from, to]] : moving_intervals(windows.values, from, to)
    total = moving.sum { |a, b| b - a }
    stats.map do |s|
      pts = windows[s.user.id]
      covered = pts.each_cons(2).sum { |(t1, _), (t2, _)| t2 - t1 <= COVER_STEP ? overlap(t1, t2, moving) : 0 }
      km = pts.each_cons(2).sum { |(_, a), (_, b)| dist(a, b) } / 1000.0
      Source.new(user: s.user, count: pts.size, coverage: total.positive? ? (covered.to_f / total).clamp(0.0, 1.0) : 0.0,
                 km:)
    end
  end

  # union of [t1, t2] of every source's steps faster than MOVING_MPS (at most MOVING_STEP apart)
  def moving_intervals(windows, from, to)
    steps = windows.flat_map do |pts|
      pts.each_cons(2).filter_map do |(t1, a), (t2, b)|
        dt = t2 - t1
        [t1, t2] if dt.positive? && dt <= MOVING_STEP && dist(a, b) / dt >= MOVING_MPS
      end
    end.sort
    merged = steps.each_with_object([]) do |(a, b), out|
      out.last && a <= out.last[1] ? out.last[1] = [out.last[1], b].max : out << [a, b]
    end
    merged.sum { |a, b| b - a } >= 60 ? merged : [[from, to]]
  end

  # seconds of [t1, t2] inside the sorted, disjoint intervals
  def overlap(t1, t2, intervals)
    i = intervals.bsearch_index { |(_, b)| b > t1 } or return 0
    sum = 0
    while i < intervals.size && intervals[i][0] < t2
      a, b = intervals[i]
      sum += [t2, b].min - [t1, a].max
      i += 1
    end
    sum
  end

  # [[ts, [lon, lat]], ...] of the day: not copied by a pick, not flagged, accuracy at most MAX_ACCURACY_M
  def good(user)
    (@good ||= {})[user.id] ||= begin
      from, to = TrackPick::Config.day_range(date)
      ActiveRecord::Base.connection.select_rows(
        ActiveRecord::Base.sanitize_sql_array([<<~SQL, user.id, from, to, Gtfs::Config::MAX_ACCURACY_M])
          SELECT timestamp, ST_X(lonlat::geometry), ST_Y(lonlat::geometry)
          FROM points
          WHERE user_id = ? AND timestamp >= ? AND timestamp < ? AND lonlat IS NOT NULL
            AND anomaly IS NOT TRUE AND (accuracy IS NULL OR accuracy <= ?)
            AND NOT EXISTS (SELECT 1 FROM track_pick_copies tc WHERE tc.target_point_id = points.id)
            AND points.tracker_id IS DISTINCT FROM 'track-pick-gtfs'
          ORDER BY timestamp
        SQL
      ).map { |ts, lon, lat| [ts.to_i, [lon.to_f, lat.to_f]] }
    end
  end

  def best_source(sources)
    sources.select { |s| s.count >= 2 }.max_by { |s| [s.coverage.round(2), s.count] }
  end

  # "Otthon → Keleti pályaudvar M": the confirmed visit or the stop of a ride next to each end
  # a round trip from one place and back is "<place> környéke"
  def move_title(from, to)
    a = place_at(from, :start)
    b = place_at(to, :end)
    return "#{a} környéke" if a && a == b

    [a, b].map { |p| p || '…' }.join(' → ')
  end

  def place_at(ts, side)
    near = @rides.map { |r| [ride_span(r), r] }.find do |(from, to), _|
      side == :start ? ts.between?(to - 60, to + 900) : ts.between?(from - 900, from + 60)
    end
    if near
      s = near[1].segment
      return side == :start ? s.alighting_stop_name : s.boarding_stop_name
    end
    visit_name(ts, side)
  end

  # the visit ending at the segment's start / starting at its end; a confirmed one first.
  # Visits carry no name of their own here: the place's name without its "(House)" type.
  def visit_name(ts, side)
    t = Time.zone.at(ts)
    scope = Visit.includes(:place).where(user_id: TrackPick::Config.target_user.id, deleted_at: nil)
    scope = if side == :start
              scope.where(ended_at: (t - 30.minutes)..(t + 15.minutes)).order(status: :desc, ended_at: :desc)
            else
              scope.where(started_at: (t - 15.minutes)..(t + 30.minutes)).order(status: :desc, started_at: :asc)
            end
    v = scope.first
    v && (v.name.presence || v.place&.name.to_s.sub(/\s*\([^)]*\)\z/, '').presence)
  rescue StandardError
    nil
  end

  def dist((lon1, lat1), (lon2, lat2))
    Gtfs::Matching::Geo.haversine(lon1, lat1, lon2, lat2)
  end
end
