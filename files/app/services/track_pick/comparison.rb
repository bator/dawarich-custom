# frozen_string_literal: true

# Read-only statistics of one day's points per source user.
class TrackPick::Comparison
  EARTH_RADIUS_M = 6_371_000.0
  Stat = Struct.new(:user, :count, :first_ts, :last_ts, :km, :gaps, :longest_gap, :coords, :times, :copied, keyword_init: true) do
    def bp_times = times.zip(coords).select { |_, c| TrackPick::Comparison.budapest?(c) }.map(&:first)
    def bp_coords = coords.select { |c| TrackPick::Comparison.budapest?(c) }

    # consecutive runs inside the bbox (no straight lines across exits)
    def bp_runs = coords.chunk_while { |a, b| TrackPick::Comparison.budapest?(a) == TrackPick::Comparison.budapest?(b) }
                        .select { |run| TrackPick::Comparison.budapest?(run.first) }

    def bp_median_gap
      gaps = bp_times.each_cons(2).map { |a, b| b - a }.sort
      gaps.empty? ? nil : gaps[gaps.size / 2]
    end
  end
  # inner city: Kelenföld to Keleti, Belváros (fixed, same for all users)
  BUDAPEST = { lat: 47.46..47.53, lon: 19.02..19.11 }.freeze

  def self.budapest?((lon, lat))
    BUDAPEST[:lat].cover?(lat) && BUDAPEST[:lon].cover?(lon)
  end

  attr_reader :date

  def initialize(date)
    @date = date
  end

  def call
    @call ||= TrackPick::Config.source_users.map { |user| stat_for(user) }
  end

  def to_text
    zone = TrackPick::Config.zone
    lines = ["Napi track-összehasonlítás – #{date.iso8601} (#{TrackPick::Config::TIME_ZONE})"]
    call.each do |s|
      label = "#{TrackPick::Config.handle(s.user)} (id #{s.user.id})"
      if s.count.zero?
        lines << "- #{label}: nincs saját pont#{s.copied.positive? ? " (+#{s.copied} átmásolt)" : ''}"
        next
      end
      span = "#{Time.zone.at(s.first_ts).in_time_zone(zone).strftime('%H:%M')}–" \
             "#{Time.zone.at(s.last_ts).in_time_zone(zone).strftime('%H:%M')}"
      lines << "- #{label}: #{s.count} pont, #{span} (#{duration(s.last_ts - s.first_ts)}), " \
               "#{format('%.1f', s.km)} km, #{s.gaps} szünet >#{TrackPick::Config::GAP_SECONDS / 60} perc" \
               "#{s.gaps.positive? ? " (leghosszabb #{duration(s.longest_gap)})" : ''}" \
               "#{s.copied.positive? ? "; +#{s.copied} átmásolt pont (nincs a térképen/statban)" : ''}"
    end
    lines << 'Budapest belváros (lat 47.46–47.53, lon 19.02–19.11, Kelenföld–Keleti):'
    call.each do |s|
      n = s.count.zero? ? 0 : s.bp_times.size
      med = n > 1 ? "medián #{s.bp_median_gap} s a fixek között" : 'nincs elég pont'
      lines << "- #{TrackPick::Config.handle(s.user)}: #{n} pont, #{med}"
    end
    lines.join("\n")
  end

  def duration(seconds)
    h, m = (seconds.to_i / 60).divmod(60)
    h.positive? ? "#{h} ó #{m} p" : "#{m} p"
  end

  private

  def stat_for(user)
    from, to = TrackPick::Config.day_range(date)
    rows = ActiveRecord::Base.connection.select_rows(
      ActiveRecord::Base.sanitize_sql_array([<<~SQL, user.id, from, to])
        SELECT timestamp, ST_X(lonlat::geometry), ST_Y(lonlat::geometry)
        FROM points
        WHERE user_id = ? AND timestamp >= ? AND timestamp < ? AND lonlat IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM track_pick_copies tc WHERE tc.target_point_id = points.id) -- K1: copied by a pick
        ORDER BY timestamp
      SQL
    ).map { |ts, lon, lat| [ts.to_i, lon.to_f, lat.to_f] }

    km = 0.0
    gaps = 0
    longest = 0
    rows.each_cons(2) do |(t1, lon1, lat1), (t2, lon2, lat2)|
      km += haversine(lon1, lat1, lon2, lat2) / 1000.0
      dt = t2 - t1
      next unless dt > TrackPick::Config::GAP_SECONDS

      gaps += 1
      longest = dt if dt > longest
    end
    Stat.new(user:, count: rows.size, first_ts: rows.first&.first, last_ts: rows.last&.first, km:, gaps:,
             longest_gap: longest, coords: rows.map { |_, lon, lat| [lon, lat] }, times: rows.map(&:first), copied: copied_count(user, from, to))
  end

  def copied_count(user, from, to)
    ActiveRecord::Base.connection.select_value(
      "SELECT count(*) FROM track_pick_copies tc JOIN points p ON p.id = tc.target_point_id " \
      "WHERE tc.target_user_id = #{user.id.to_i} AND p.timestamp >= #{from.to_i} AND p.timestamp < #{to.to_i}"
    ).to_i
  end

  def haversine(lon1, lat1, lon2, lat2)
    rad = Math::PI / 180
    dlat = (lat2 - lat1) * rad
    dlon = (lon2 - lon1) * rad
    a = (Math.sin(dlat / 2)**2) + (Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * (Math.sin(dlon / 2)**2))
    2 * EARTH_RADIUS_M * Math.asin(Math.sqrt(a))
  end
end
