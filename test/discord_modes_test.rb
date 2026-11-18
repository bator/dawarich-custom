# frozen_string_literal: true

require_relative 'test_helper'

# DISCORD_TRANSIT_USER_MODES: per user, only rides of the listed vehicles
# are posted to Discord (the GPS logger's account: metro only).
class DiscordModesTest < Minitest::Test
  C = Gtfs::Discord::Config
  Ride = Struct.new(:id, :mode)

  # a relation stand-in: only #limit is called when no mode is listed
  Limited = Struct.new(:calls) do
    def limit(n)
      calls << n
      :limited
    end
  end

  def test_listed_user_gets_only_its_modes
    assert_equal %w[metro tram], C.user_modes('8:metro, 8:Tram ,2:bus', 8)
    assert_equal %w[bus], C.user_modes('8:metro, 8:Tram ,2:bus', 2)
  end

  def test_unlisted_user_and_empty_setting_mean_every_ride
    assert_nil C.user_modes('8:metro', 5)
    assert_nil C.user_modes('', 8)
    assert_nil C.user_modes(nil, 8)
  end

  def test_malformed_entries_are_ignored
    assert_equal %w[metro], C.user_modes('metro,x:metro,8:,:tram,8:metro,8:metro', 8)
  end

  def test_only_modes_keeps_listed_vehicles_up_to_the_limit
    rides = [Ride.new(1, 'bus'), Ride.new(2, 'metro'), Ride.new(3, 'tram'), Ride.new(4, 'metro'), Ride.new(5, 'metro')]
    assert_equal [2, 4], Gtfs::Discord::NotifyJob.only_modes(rides, %w[metro], 2).map(&:id)
  end

  def test_only_modes_without_modes_limits_the_relation
    relation = Limited.new([])
    assert_equal :limited, Gtfs::Discord::NotifyJob.only_modes(relation, nil, 10)
    assert_equal [10], relation.calls
  end
end
