# frozen_string_literal: true

# The rides of a period as a network on the map (overview card, since
# 2026-10-20). One path per stop pair (a corridor), both directions and all
# lines together: the timetable's line between the two stops of its latest
# ride (Gtfs::Discord::RideMap: the trip's shape, e.g. the pfaedle-matched MÁV
# railway, else the timetable stops), in the colour of its most used line,
# wider with more rides. Privacy zones are cut out the way the Discord map
# image does it, and a stop inside one is left out.
class Gtfs::NetworkMap
  LABELS = 6 # stops that get a name on the map

  # segment: latest ride of the most used line (colour); lines: [[segment, rides], ...];
  # runs: [[[lon, lat], ...], ...] (one run per piece outside the privacy zones)
  Path = Struct.new(:segment, :count, :lines, :from, :to, :runs, keyword_init: true)
  Stop = Struct.new(:name, :lon, :lat, :count, keyword_init: true)

  def initialize(rides, user:)
    @rides = rides
    @zones = Users::PrivacyZones.new(user).call
    @positions = {}
  end

  def empty? = paths.empty?

  def paths
    @paths ||= begin
      groups = @rides.group_by { |s| [s.boarding_stop_name.to_s, s.alighting_stop_name.to_s].sort }
      groups.filter_map do |(from, to), list|
        ride = list.max_by(&:started_at)
        runs, board, alight = geometry(ride)
        next if runs.blank?

        @positions[ride.boarding_stop_name] ||= board
        @positions[ride.alighting_stop_name] ||= alight
        lines = list.group_by { |s| s.route_short_name.presence || s.route_long_name.to_s }.values
                    .map { |same| [same.max_by(&:started_at), same.size] }.sort_by { |_, n| -n }
        Path.new(segment: lines.first.first, count: list.size, lines:, from:, to:, runs:)
      end.sort_by { |path| [-path.count, path.from] }
    end
  end

  # Stops with a visible position, most used first.
  def stops
    @stops ||= begin
      paths # fills @positions
      counts = Hash.new(0)
      @rides.each do |s|
        counts[s.boarding_stop_name] += 1
        counts[s.alighting_stop_name] += 1
      end
      counts.filter_map do |name, count|
        lon, lat = @positions[name]
        Stop.new(name:, lon:, lat:, count:) if name.present? && lon
      end.sort_by { |stop| -stop.count }
    end
  end

  # [[west, south], [east, north]] of everything drawn.
  def bounds
    coordinates = paths.flat_map { |path| path.runs.flatten(1) } + stops.map { |s| [s.lon, s.lat] }
    lons = coordinates.map(&:first)
    lats = coordinates.map(&:last)
    [[lons.min, lats.min], [lons.max, lats.max]]
  end

  private

  # [runs, board, alight] of one ride, cached: the shape lookup takes up to
  # half a second a corridor. The key holds the zones, so a changed privacy
  # zone is never served from an older cut.
  def geometry(ride)
    key = ['gtfs/network_map', ride.id, ride.updated_at.to_i, Digest::SHA256.hexdigest(@zones.to_json)]
    Rails.cache.fetch(key, expires_in: 1.day) do
      result = Gtfs::Discord::RideMap.new(ride, zones: @zones).call
      [result.line.presence || result.gps, result.board, result.alight]
    end
  end
end
