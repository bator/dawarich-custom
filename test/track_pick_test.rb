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

  def test_split_actions
    assert_equal({ kind: :split_pick, index: '2', src: 'g' }, parse('p:2:g'))
    assert_equal({ kind: :split_pick, index: '3', src: '8' }, parse('p:3:8'))
    assert_equal({ kind: :split_confirm }, parse('pok'))
    assert_nil parse('p:2:x')
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

class TrackPickSplitMessageTest < Minitest::Test
  M = TrackPick::Message

  def target = TrackPick::Config.target_user.id.to_s

  def ride
    { 'index' => 2, 'kind' => 'ride', 'from' => 1_763_398_920, 'to' => 1_763_399_760, 'title' => 'M4 Kelenföld → Keleti',
      'gtfs' => true, 'recommended' => 'g',
      'sources' => [{ 'user_id' => target, 'handle' => 'minekte', 'count' => 5, 'coverage' => 0.02 },
                    { 'user_id' => '8', 'handle' => 'toth.bator', 'count' => 0, 'coverage' => 0.0 }] }
  end

  def move
    { 'index' => 1, 'kind' => 'move', 'from' => 1_763_350_000, 'to' => 1_763_398_900, 'title' => '… → Bikás park',
      'gtfs' => false, 'recommended' => '8',
      'sources' => [{ 'user_id' => target, 'handle' => 'minekte', 'count' => 152, 'coverage' => 0.38 },
                    { 'user_id' => '8', 'handle' => 'toth.bator', 'count' => 2647, 'coverage' => 0.93 }] }
  end

  def test_initial_picks_are_the_recommendations_that_copy
    assert_equal({ '2' => 'g', '1' => '8' }, M.initial_picks([ride, move, move.merge('index' => 3, 'recommended' => target)]))
  end

  def test_choices_keep_own_skip_empty_sources_and_add_the_line
    assert_equal [target, 'g'], M.split_choices(ride).map(&:first)
    assert_equal [target, '8'], M.split_choices(move).map(&:first)
  end

  def test_buttons_green_on_the_pick_star_on_the_recommendation
    date = Date.new(2026, 11, 17)
    buttons = M.split_segment_components(date, ride, { '2' => 'g' }).first[:components]
    assert_equal ["trackpick:2026-11-17:p:2:#{target}", 'trackpick:2026-11-17:p:2:g'], buttons.map { |b| b[:custom_id] }
    assert_equal [M::SECONDARY, M::SUCCESS], buttons.map { |b| b[:style] }
    assert buttons.last[:label].start_with?('★ ')
    own = M.split_segment_components(date, ride, {}).first[:components]
    assert_equal [M::SUCCESS, M::SECONDARY], own.map { |b| b[:style] }
  end

  def test_header_lists_every_pick_and_counts
    file = { 'summary' => 'S', 'segments' => [move, ride] }
    payload = M.split_header_payload(Date.new(2026, 11, 17), file, { '2' => 'g' })
    text = payload[:embeds].first[:description]
    assert_includes text, '2 szakasz · 1 átvesz, 1 marad'
    assert_includes text, '→ **A menetrend**'
    assert_includes text, '→ **saját, marad**'
    assert_equal %w[trackpick:2026-11-17:pok trackpick:2026-11-17:skip],
                 payload[:components].first[:components].map { |c| c[:custom_id] }
  end
end

class TrackPickSplitHandlerTest < Minitest::Test
  C = TrackPick::Config
  DATE = Date.new(2026, 1, 2)

  def setup
    @dir = Dir.mktmpdir('trackpick')
    @old = C::STATE_DIR
    C.send(:remove_const, :STATE_DIR)
    C.const_set(:STATE_DIR, @dir)
  end

  def teardown
    C.send(:remove_const, :STATE_DIR)
    C.const_set(:STATE_DIR, @old)
    FileUtils.rm_rf(@dir)
  end

  def interaction(custom_id, message_id)
    { 'type' => 3, 'channel_id' => C.channel_id.to_s, 'application_id' => '99',
      'member' => { 'user' => { 'id' => C.allowed_discord_user_ids.first.to_s, 'username' => 't' } },
      'message' => { 'id' => message_id, 'author' => { 'id' => '99' } },
      'data' => { 'custom_id' => custom_id } }
  end

  def test_segment_click_stores_the_pick_and_restyles_only_that_message
    target = C.target_user.id.to_s
    seg = { 'index' => 2, 'kind' => 'move', 'from' => 1, 'to' => 2, 'title' => 't', 'gtfs' => false, 'recommended' => '8',
            'sources' => [{ 'user_id' => target, 'handle' => 'a', 'count' => 5, 'coverage' => 0.1 },
                          { 'user_id' => '8', 'handle' => 'b', 'count' => 9, 'coverage' => 0.9 }] }
    TrackPick::Segments.write_file(DATE, { 'date' => DATE.iso8601, 'message_id' => '100', 'summary' => 'S',
                                           'segment_messages' => { '2' => '102' }, 'segments' => [seg] })
    TrackPick::Segments.save_picks!(DATE, { '2' => '8' })
    handler = TrackPick::DiscordHandler.new

    plan = handler.prepare(interaction("trackpick:#{DATE}:p:2:#{target}", '102'))
    assert_equal 7, plan.response[:type]
    assert_equal({}, TrackPick::Segments.load_picks(DATE)) # own = stays: no pick
    styles = plan.response[:data][:components].first[:components].map { |b| b[:style] }
    assert_equal [TrackPick::Message::SUCCESS, TrackPick::Message::SECONDARY], styles

    edited = []
    client = Object.new
    client.define_singleton_method(:edit_message) { |_c, id, payload| edited << [id, payload] }
    Gtfs::Discord::Client.define_singleton_method(:new) { |*| client }
    begin
      plan.work.call
    ensure
      Gtfs::Discord::Client.singleton_class.send(:remove_method, :new)
    end
    assert_equal '100', edited.first[0]
    assert_includes edited.first[1][:embeds].first[:description], '0 átvesz, 1 marad'

    stale = handler.prepare(interaction("trackpick:#{DATE}:p:2:8", '555'))
    assert_equal 4, stale.response[:type] # ephemeral: an older message
    assert_equal({}, TrackPick::Segments.load_picks(DATE))
  end
end
