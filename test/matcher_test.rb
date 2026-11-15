# frozen_string_literal: true

require_relative 'test_helper'

class FollowingPointsTest < Minitest::Test
  include TestGeo
  W = Struct.new(:points, :end_ts, :start_ts, :kind, keyword_init: true) do
    def gap? = kind == :gap
  end

  def matcher(ts_list)
    m = Gtfs::SegmentMatcher.allocate
    m.instance_variable_set(:@stream, ts_list.map { |t| mp(t) })
    m
  end

  def test_budget_and_one_free_gap
    m = matcher([1010, 1100, 1700, 1800, 1900, 1950])
    assert_equal [1010, 1100, 1700, 1800, 1900], m.send(:following_points, 1000, nil).map(&:ts)
    assert_equal [1010, 1100], m.send(:following_points, 1000, 1700).map(&:ts)
    assert_equal [1010, 1700], matcher([1010, 1700, 2400]).send(:following_points, 1000, nil).map(&:ts) # a 2nd gap stops
    assert_equal [2200], matcher([2200]).send(:following_points, 1000, nil).map(&:ts) # exactly ARRIVAL_MAX_GAP_SECS
    assert_equal [], matcher([2201]).send(:following_points, 1000, nil)
  end

  def test_arrival_tries_need_100_m_steps_and_stop_at_six
    base = [19.0, 47.5]
    m = Gtfs::SegmentMatcher.allocate
    last = mp(1000, *base)
    m.instance_variable_set(:@stream, [50, 150, 180].each_with_index.map { |d, i| mp(1010 + (i * 10), *north(*base, d)) })
    window = W.new(points: [last], end_ts: 1000)
    tries = m.send(:arrival_tries, window)
    assert_equal [2], tries.map(&:size) # 150 m is the only step of 100 m (180 m is 30 m on)

    m.instance_variable_set(:@stream, (1..10).map { |i| mp(1000 + (i * 10), *north(*base, i * 150)) })
    assert_equal [1, 2, 3, 4, 5, 6], m.send(:arrival_tries, window).map(&:size)
  end

  def test_late_arrival_stops_after_the_next_movement_window
    m = Gtfs::SegmentMatcher.allocate
    m.instance_variable_set(:@windows, [W.new(start_ts: 500, end_ts: 1000, kind: :moving),
                                        W.new(start_ts: 1000, end_ts: 1600, kind: :gap),
                                        W.new(start_ts: 1600, end_ts: 2000, kind: :moving),
                                        W.new(start_ts: 3000, end_ts: 3500, kind: :moving)])
    assert_equal 2001, m.send(:next_movement_start, W.new(end_ts: 1000)) # over the gap, to the end of the next movement
    assert_nil m.send(:next_movement_start, W.new(end_ts: 3500))
  end
end

class RailEndpointTimingTest < Minitest::Test
  Stop = Struct.new(:departure_secs, :arrival_secs, keyword_init: true)

  # dep 07:37 (27 420 s), arr 08:16 (29 760 s): the IC 849 of 2026-11-12
  def scorer(departure_confirmed:)
    s = Gtfs::Matching::Scorer.allocate
    s.instance_variable_set(:@board, Stop.new(departure_secs: 27_420))
    s.instance_variable_set(:@alight, Stop.new(arrival_secs: 29_760))
    s.define_singleton_method(:rail_departure_point) { |*| departure_confirmed ? Object.new : nil }
    s.define_singleton_method(:underground_metro?) { false }
    s
  end

  def score(s, first_t, last_t)
    scheduled = 29_760 - 27_420
    s.send(:rail_endpoint_time_score, first_t, last_t, last_t - first_t, scheduled,
           Gtfs::Config::GAP_DURATION_TOLERANCE * scheduled)
  end

  def test_a_train_that_makes_up_time_is_accepted
    r = score(scorer(departure_confirmed: true), 27_660, 29_850) # left +240 s, arrived +90 s
    assert_nil r[:reason]
    assert_equal 240, r[:delay]
    assert_operator r[:score], :>=, Gtfs::Config::MIN_TIME_SCORE
  end

  def test_a_standing_fix_before_the_timetable_is_not_an_early_departure
    standing = score(scorer(departure_confirmed: false), 27_420 - 360, 29_760)
    left_early = score(scorer(departure_confirmed: true), 27_420 - 360, 29_760)
    assert_operator standing[:score], :>, left_early[:score]
    assert_operator standing[:score], :>=, Gtfs::Config::MIN_TIME_SCORE
  end

  def test_a_confirmed_departure_far_off_the_timetable_is_rejected
    r = score(scorer(departure_confirmed: true), 27_420 - 901, 29_760 - 901)
    assert_equal 'delay outside the tolerance', r[:reason]
  end
end

# ported from spec/services/gtfs/sparse_join_transfer_spec.rb (its fixtures file was lost)
class SparseJoinTest < Minitest::Test
  include TestGeo
  WD = Gtfs::Matching::WindowDetector

  def hms(h, m, s = 0) = Time.zone.parse('2026-10-15').to_i + (h * 3600) + (m * 60) + s

  def sparse_train
    pts = [hms(7, 41), hms(7, 50), hms(8, 0), hms(8, 10), hms(8, 20, 30)].each_with_index
                                                                          .map { |t, i| mp(t, 18.4 + (i * 0.15), 47.2 + (i * 0.06)) }
    WD::Window.new(points: pts, kind: :moving, pauses: [], moving_start: 0, sparse: true)
  end

  def bus
    pts = (0..60).map { |i| mp(hms(8, 23) + (i * 10), 19.0201 + (i * 0.0004), 47.4646 + (i * 0.0001)) }
    WD::Window.new(points: pts, kind: :moving, pauses: [], moving_start: 0, sparse: false)
  end

  def walk
    pts = (0..12).map { |i| mp(hms(8, 21) + (i * 10), 19.0201 + (i * 0.00002), 47.4646) }
    WD::Window.new(points: pts, kind: :slow, pauses: [], sparse: false)
  end

  def test_joins_a_sparse_ride_and_a_quick_transfer_keeping_the_seam
    joined = WD.join_sparse([sparse_train, bus])
    assert_equal 1, joined.size
    assert_equal true, joined.first.sparse
    assert_equal [[4, 5]], joined.first.pauses
  end

  def test_never_joins_a_walking_window
    assert_equal 2, WD.join_sparse([sparse_train, walk]).size
  end
end

class MatchCasesSkipTest < Minitest::Test
  Feeds = Struct.new(:has) do
    def version_for(_feed, _date) = has ? 1 : nil
  end

  def test_a_file_case_naming_its_feed_is_skipped_without_timetable
    mc = Gtfs::MatchCases.allocate
    kase = { id: 'x', kind: 'file', user_id: 2, date: Date.new(2026, 11, 7), feed_key: 'budapest' }
    r = mc.send(:skip, kase, Feeds.new(false), kase[:date])
    assert r&.skipped
    assert_equal 'no_timetable', r.grade
    assert_nil mc.send(:skip, kase, Feeds.new(true), kase[:date])
    assert_nil mc.send(:skip, kase.except(:feed_key), Feeds.new(false), kase[:date]) # no feed: still graded
  end
end
