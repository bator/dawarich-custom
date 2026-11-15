# frozen_string_literal: true

require_relative 'test_helper'

class TrackPickMessageTest < Minitest::Test
  M = TrackPick::Message

  def test_encode_and_decode_picks
    assert_equal '2u8.4g', M.encode_picks({ '4' => 'g', '2' => '8' })
    assert_equal '-', M.encode_picks({})
    assert_equal({ '2' => '8', '4' => 'g' }, M.decode_picks('2u8.4g'))
    assert_equal({}, M.decode_picks('-'))
    assert_nil M.decode_picks('2x')
  end

  def test_picks_from_values_flags_two_sources_for_one_segment
    assert_equal [{ '2' => '8', '4' => 'g' }, false], M.picks_from_values(%w[2:u8 4:g])
    assert_equal true, M.picks_from_values(%w[2:u8 2:g]).last
  end

  def test_restate_segments_rewrites_select_and_confirm_only
    rows = [
      { 'type' => 1, 'components' => [{ 'type' => 3, 'custom_id' => 'trackpick:2026-11-08:s:-', 'options' => [
        { 'label' => '② – 2 toth.bator', 'value' => '2:u8' }, { 'label' => '② – A menetrendi vonal', 'value' => '2:g' }
      ] }] },
      { 'type' => 1, 'components' => [
        { 'type' => 2, 'custom_id' => 'trackpick:2026-11-08:rec' },
        { 'type' => 2, 'custom_id' => 'trackpick:2026-11-08:sok:-', 'disabled' => true },
        { 'type' => 2, 'custom_id' => 'trackpick:2026-11-08:skip' }
      ] }
    ]
    out, line = M.restate_segments(rows, date: Date.new(2026, 11, 8), picks: { '2' => 'g' })
    select = out[0]['components'][0]
    rec, ok, skip = out[1]['components']
    assert_equal 'trackpick:2026-11-08:s:2g', select['custom_id']
    assert_equal [false, true], select['options'].map { |o| o['default'] }
    assert_equal 'trackpick:2026-11-08:sok:2g', ok['custom_id']
    assert_equal false, ok['disabled']
    assert_equal 'trackpick:2026-11-08:rec', rec['custom_id']
    assert_equal 'trackpick:2026-11-08:skip', skip['custom_id']
    assert_match(/\AKiválasztva: ② – A menetrendi vonal\./, line)

    out, line = M.restate_segments(rows, date: Date.new(2026, 11, 8), picks: {}, note: 'X')
    assert_equal true, out[1]['components'][1]['disabled']
    assert_match(/\AX Nincs kiválasztott szakasz/, line)
  end

  def test_dropped_line_lists_what_did_not_fit
    seg = TrackPick::Segments::Segment.new(from: Time.zone.parse('2026-11-08 21:00').to_i,
                                           to: Time.zone.parse('2026-11-08 21:30').to_i, title: 'Keleti → Otthon')
    assert_nil M.dropped_line([])
    assert_match(/Nem fért a listába.*Keleti → Otthon/, M.dropped_line([seg]))
  end
end

class TrackPickParseTest < Minitest::Test
  def parse(rest, values = []) = TrackPick::DiscordHandler.new.send(:parse, rest, values)

  def test_segment_actions
    assert_equal({ kind: :seg_select, picks: { '2' => '8' } }, parse('s:-', ['2:u8']))
    assert_equal({ kind: :seg_select, picks: {}, note: 'Szakaszonként egy forrást válassz.' }, parse('s:-', %w[2:u8 2:g]))
    assert_equal({ kind: :seg_confirm, picks: { '2' => '8', '4' => 'g' } }, parse('sok:2u8.4g'))
    assert_nil parse('sok:2x')
    assert_equal({ kind: :seg_confirm, picks: :recommended }, parse('rec'))
  end

  def test_older_message_formats_still_parse
    assert_equal({ kind: :confirm, day: '8', bp: 'same', picks: {} }, parse('ok:8:same:-'))
    assert_equal({ kind: :confirm, day: '8', bp: 'same', picks: {} }, parse('ok:8:same'))
    assert_equal({ kind: :skip }, parse('skip'))
  end
end

class TrackPickSegmentsTest < Minitest::Test
  include TestGeo
  S = TrackPick::Segments

  def seg(kind, from, to) = S::Segment.new(kind:, from:, to:, title: "#{kind} #{from}")

  def test_fit_keeps_every_ride_then_the_longest_moves
    segs = [seg(:move, 0, 50), seg(:ride, 100, 200), seg(:move, 210, 400), seg(:ride, 500, 600),
            seg(:move, 610, 620), seg(:ride, 700, 800), seg(:move, 810, 1000), seg(:ride, 1100, 1200),
            seg(:move, 1210, 1215), seg(:ride, 1300, 1400)]
    kept, dropped = S.fit(segs, 8)
    assert_equal 8, kept.size
    assert_equal 5, kept.count { |s| s.kind == :ride }
    assert_equal [610, 1210], dropped.map(&:from) # the two shortest moves
    assert_equal kept.map(&:from).sort, kept.map(&:from)
    assert_equal [segs.first(3), []], S.fit(segs.first(3), 8)
  end

  def test_overlap_with_sorted_disjoint_intervals
    s = S.allocate
    intervals = [[0, 120], [150, 300]]
    assert_equal 30, s.send(:overlap, 100, 160, intervals)
    assert_equal 0, s.send(:overlap, 130, 140, intervals)
    assert_equal 0, s.send(:overlap, 400, 500, intervals)
  end

  def test_moving_intervals_union_and_fallback
    s = S.allocate
    p = [19.0, 47.5]
    a = [[0, p], [60, north(*p, 120)], [120, north(*p, 120)]] # 2 m/s, then standing
    b = [[50, p], [100, north(*p, 100)]]                         # 2 m/s
    assert_equal [[0, 100]], s.send(:moving_intervals, [a, b], 0, 200)
    short = [[0, p], [30, north(*p, 60)]] # 30 s of movement only: the whole segment counts
    assert_equal [[0, 200]], s.send(:moving_intervals, [short], 0, 200)
  end
end

class LateRideLineTest < Minitest::Test
  Seg = Struct.new(:started_at, :ended_at, :created_at, keyword_init: true)

  def with_saved(list)
    orig = TrackPick::Segments.method(:load)
    TrackPick::Segments.define_singleton_method(:load) { |_date| list }
    yield
  ensure
    TrackPick::Segments.define_singleton_method(:load, orig)
  end

  def test_offered_ride_is_not_late
    lr = TrackPick::LateRideLine.new(Date.new(2026, 11, 12), User.new(id: 0))
    decision = { 'time' => '2026-11-13T06:00:46+01:00' }
    with_saved([{ 'kind' => 'ride', 'from' => 1000, 'to' => 2000 }, { 'kind' => 'move', 'from' => 3000, 'to' => 4000 }]) do
      assert lr.send(:offered?, Seg.new(started_at: 1500, ended_at: 2500), decision)
      refute lr.send(:offered?, Seg.new(started_at: 3100, ended_at: 3900), decision) # only a move was there
    end
    with_saved(nil) do # an older message: created before the decision means offered
      assert lr.send(:offered?, Seg.new(created_at: Time.zone.parse('2026-11-13 05:00')), decision)
      refute lr.send(:offered?, Seg.new(created_at: Time.zone.parse('2026-11-14 10:00')), decision)
    end
  end
end
