# frozen_string_literal: true

require_relative 'test_helper'

# Whose walks the walk layer shows, each in its own colour (Gtfs::WalkOwners).
class WalkOwnersTest < Minitest::Test
  O = Gtfs::WalkOwners

  def group
    @group ||= TrackPick::Config.source_users
  end

  def test_a_source_account_sees_every_source_account_own_first
    skip 'fewer than two TrackPick source accounts' if group.size < 2
    viewer = group.last
    owners = O.for(viewer)
    assert_equal [viewer.id] + (group.map(&:id) - [viewer.id]), owners.map { |o| o.user.id }
    assert owners.first.own
    assert_equal O::OWN_COLOR, owners.first.color
    assert_equal O::OTHER_COLORS.first, owners[1].color
    assert(owners.none? { |o| o.label.to_s.include?('@') }, 'a label is never an e-mail address')
  end

  def test_anyone_else_sees_only_own_walks_unlabelled
    other = User.where.not(id: group.map(&:id)).first
    skip 'no account outside the TrackPick sources' unless other
    owners = O.for(other)
    assert_equal [[other.id, O::OWN_COLOR, nil, true]], owners.map { |o| [o.user.id, o.color, o.label, o.own] }
  end

  def test_another_owners_walks_also_pass_the_viewers_zones
    skip 'fewer than two TrackPick source accounts' if group.size < 2
    viewer, other = group.first, group.last
    own, theirs = O.for(viewer)
    assert_equal Users::PrivacyZones.new(viewer).call, O.zones(own, viewer)
    assert_equal Users::PrivacyZones.new(other).call + Users::PrivacyZones.new(viewer).call, O.zones(theirs, viewer)
  end

  def test_serializer_adds_the_owner_to_every_feature
    leg = TransitWalkLeg.new(id: 1, started_at: 0, ended_at: 60, source: 'raw', stats: {},
                             parts: [{ 'source' => 'raw', 'coords' => [[19.0, 47.5], [19.001, 47.5]] }])
    owner = O::Owner.new(user: nil, color: '#7C3AED', label: 'GPS', own: false)
    features = Api::TransitWalkLegSerializer.new(leg, owner:).features
    refute_empty features
    assert(features.all? { |f| f[:properties].values_at(:owner_color, :owner_label, :own) == ['#7C3AED', 'GPS', false] })
    plain = Api::TransitWalkLegSerializer.new(leg).features
    assert(plain.none? { |f| f[:properties].key?(:owner_color) })
  end

  def test_another_owners_walk_at_the_same_time_is_dropped
    own = O::Owner.new(user: nil, color: O::OWN_COLOR, label: 'me', own: true)
    other = O::Owner.new(user: nil, color: '#7C3AED', label: 'logger', own: false)
    leg = ->(from, to) { TransitWalkLeg.new(started_at: from, ended_at: to) }
    pairs = [[leg.(1000, 1600), own], [leg.(1180, 1620), other], [leg.(1550, 2000), other], [leg.(3000, 3300), other]]
    kept = O.drop_shadowed(pairs)
    assert_equal [[1000, true], [1550, false], [3000, false]], kept.map { |l, o| [l.started_at, o.own] }
  end
end
