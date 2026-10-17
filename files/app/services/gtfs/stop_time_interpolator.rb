# frozen_string_literal: true

# Fills missing stop_times of ONE trip (spec 7.7):
# - only arrival or only departure given -> copy the other one;
# - untimed intermediate stops -> linear interpolation between the nearest
#   timed stops, proportional to travelled distance (shape_dist_traveled when
#   every row of the trip has it, otherwise cumulative straight-line distance
#   between consecutive stops; equal spacing if distances are unusable);
# - checks that times never decrease along the trip.
#
# rows: Array of Hashes sorted by stop_sequence with keys
#   :stop_id, :stop_sequence, :arrival_secs, :departure_secs, :dist (Float|nil)
# stop_coords: { stop_id => [lat, lon] }
# Returns a Result with the completed rows (each gets :interpolated).
class Gtfs::StopTimeInterpolator
  EARTH_RADIUS_M = 6_371_008.8

  Result = Struct.new(:rows, :valid, :first_departure_secs, :last_arrival_secs, :interpolated_count,
                      keyword_init: true)

  def self.call(rows, stop_coords = {})
    new(rows, stop_coords).call
  end

  def initialize(rows, stop_coords)
    @rows = rows.map(&:dup)
    @stop_coords = stop_coords
  end

  def call
    @rows.each do |row|
      row[:interpolated] = false
      row[:arrival_secs] ||= row[:departure_secs]
      row[:departure_secs] ||= row[:arrival_secs]
    end

    interpolated = interpolate_gaps
    Result.new(
      rows: @rows,
      valid: complete? && monotonic?,
      first_departure_secs: @rows.first&.dig(:departure_secs),
      last_arrival_secs: @rows.last&.dig(:arrival_secs),
      interpolated_count: interpolated
    )
  end

  private

  def timed?(row)
    !row[:departure_secs].nil?
  end

  def interpolate_gaps
    timed_idx = @rows.each_index.select { |i| timed?(@rows[i]) }
    return 0 if timed_idx.size < 2

    distances = cumulative_distances
    count = 0
    timed_idx.each_cons(2) do |a, b|
      next if b - a < 2

      t0 = @rows[a][:departure_secs]
      t1 = @rows[b][:arrival_secs]
      d0 = distances[a]
      span = distances[b] - d0
      ((a + 1)...b).each do |i|
        fraction = span.positive? ? (distances[i] - d0) / span : (i - a).fdiv(b - a)
        fraction = fraction.clamp(0.0, 1.0)
        secs = (t0 + ((t1 - t0) * fraction)).round
        @rows[i][:arrival_secs] = secs
        @rows[i][:departure_secs] = secs
        @rows[i][:interpolated] = true
        count += 1
      end
    end
    count
  end

  def cumulative_distances
    if @rows.all? { |r| r[:dist] }
      @rows.map { |r| r[:dist].to_f }
    else
      total = 0.0
      @rows.each_with_index.map do |row, i|
        if i.positive?
          prev = @stop_coords[@rows[i - 1][:stop_id]]
          cur = @stop_coords[row[:stop_id]]
          total += haversine(prev, cur) if prev && cur
        end
        total
      end
    end
  end

  def complete?
    @rows.all? { |r| timed?(r) }
  end

  def monotonic?
    last = nil
    @rows.each do |row|
      return false if row[:departure_secs] < row[:arrival_secs]
      return false if last && row[:arrival_secs] < last

      last = row[:departure_secs]
    end
    true
  end

  def haversine(from, to)
    lat1, lon1 = from.map { |v| v * Math::PI / 180 }
    lat2, lon2 = to.map { |v| v * Math::PI / 180 }
    h = (Math.sin((lat2 - lat1) / 2)**2) + (Math.cos(lat1) * Math.cos(lat2) * (Math.sin((lon2 - lon1) / 2)**2))
    2 * EARTH_RADIUS_M * Math.asin(Math.sqrt(h))
  end
end
