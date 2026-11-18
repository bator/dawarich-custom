# frozen_string_literal: true

require_relative 'test_helper'

# Gtfs::SegmentMatcher.vehicle_stretch_at: the evidence extend_departures
# needs before it moves a bus or tram boarding to an earlier stop.
class MatchRulesTest < Minitest::Test
  include TestGeo
  M = Gtfs::SegmentMatcher

  # fixes every `step` s, `speed_ms` m/s north from (19.0, 47.5)
  def track(t0, n, step, speed_ms)
    (0...n).map do |i|
      lon, lat = north(19.0, 47.5, i * step * speed_ms)
      mp(t0 + (i * step), lon, lat)
    end
  end

  def test_bus_departure_at_29_kmh_is_found_at_its_first_fix
    walk = track(1000, 60, 1, 1.2)                      # walking to the stop
    bus = track(1060, 20, 1, 8.0).map { |p| mp(p.ts, p.lon, p.lat + 0.00065) } # 29 km/h
    found = M.vehicle_stretch_at(walk + bus)
    refute_nil found
    assert found.between?(1050, 1062), "found at #{found}"
  end

  def test_walking_or_running_for_the_bus_is_not_a_vehicle
    assert_nil M.vehicle_stretch_at(track(0, 300, 1, 1.4))  # 5 km/h
    assert_nil M.vehicle_stretch_at(track(0, 300, 1, 3.5))  # 12.6 km/h, the phone's 23:15 jump
    assert_nil M.vehicle_stretch_at(track(0, 30, 7, 3.5))   # sparse phone, same pace
  end

  def test_a_bus_stopping_right_after_still_counts
    bus = track(0, 25, 1, 8.0)
    stand = (1..30).map { |i| mp(25 + i, bus.last.lon, bus.last.lat) }
    refute_nil M.vehicle_stretch_at(bus + stand)
  end

  def test_a_short_multipath_jump_is_not_a_vehicle
    still = track(0, 60, 1, 0.0)
    jump = still.each_with_index.map { |p, i| i == 30 ? mp(p.ts, *north(p.lon, p.lat, 150)) : p }
    assert_nil M.vehicle_stretch_at(jump)
  end
end
