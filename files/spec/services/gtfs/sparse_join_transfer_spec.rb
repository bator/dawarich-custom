# frozen_string_literal: true

require 'rails_helper'
require_relative 'matching/sparse_gps_fixtures'

# Review K3: a quick transfer (< 3 min) on a sparse track must not become
# one auto-accepted ride.
RSpec.describe 'sparse window join and transfers' do
  include GtfsSparseGpsFixtures

  let(:train) { rail_profile } # Székesfehérvár -> Kelenföld, arrives 08:21
  let(:sparse_train) do
    secs = [hms(7, 41), hms(7, 50), hms(8, 0), hms(8, 10), hms(8, 20, 30)]
    window(secs.each_with_index.map { |s, i| point(i + 1, s, *position_at(train, s)) }, moving_start: 0, sparse: true)
  end
  # a bus leaving Kelenföld eastwards at 08:23, dense
  let(:bus_window) do
    pts = (0..60).map { |i| point(100 + i, hms(8, 23) + (i * 10), 19.0201 + (i * 0.0004), 47.4646 + (i * 0.0001), speed: 8.0) }
    window(pts, moving_start: 0, sparse: false)
  end
  let(:walk) do
    pts = (0..12).map { |i| point(300 + i, hms(8, 21) + (i * 10), 19.0201 + (i * 0.00002), 47.4646, speed: 1.2) }
    window(pts, kind: :slow, sparse: false)
  end

  it 'joins a sparse ride and a quick transfer, but marks the result sparse with the seam as a pause' do
    joined = Gtfs::Matching::WindowDetector.join_sparse([sparse_train, bus_window])
    expect(joined.size).to eq(1)
    expect(joined.first.sparse).to be(true)
    expect(joined.first.pauses).to eq([[4, 5]])
  end

  it 'never joins a :slow (walking) window' do
    expect(Gtfs::Matching::WindowDetector.join_sparse([sparse_train, walk]).size).to eq(2)
  end

  it 'caps a ride scored on the joined window, so the halves are tried' do
    joined = Gtfs::Matching::WindowDetector.join_sparse([sparse_train, bus_window]).first
    result = Gtfs::Matching::Scorer.new(joined, candidate(train), train).call
    expect(result.rejected.nil? && result.confidence >= Gtfs::Config::AUTO_ACCEPT).to be(false)
  end

  it 'splits the joined window into the two rides' do
    joined = Gtfs::Matching::WindowDetector.join_sparse([sparse_train, bus_window]).first
    matcher = Gtfs::SegmentMatcher.allocate
    bus = rail_profile([['Kelenföld', 19.0201, 47.4646, nil, hms(8, 23)],
                        ['Somewhere', 19.0441, 47.4706, hms(8, 33), nil]], route_type: 3, line: '153')
    mk = lambda do |prof, conf, trip|
      Gtfs::Matching::Scorer::Score.new(candidate: candidate(prof).tap { |c| c.trip_gtfs_id = trip }, profile: prof,
                                        confidence: conf, raw_confidence: conf, features: {}, delay_secs: 0,
                                        board: prof.stops.first, alight: prof.stops.last, caps: [],
                                        distance_m: 5000, started_at: 0, ended_at: 0)
    end
    allow(matcher).to receive(:evaluate) do |win, _stats|
      if win.points.size == joined.points.size then [mk.call(train, 0.74, 'IC849'), []]
      elsif win.points.first.id == 1 then [mk.call(train, 0.74, 'IC849'), []]
      else [mk.call(bus, 0.9, 'BUS153'), []]
      end
    end
    matches = matcher.send(:match_window, joined, 0, Hash.new(0))
    expect(matches.map { |m| m.score.candidate.trip_gtfs_id }).to eq(%w[IC849 BUS153])
  end
end
