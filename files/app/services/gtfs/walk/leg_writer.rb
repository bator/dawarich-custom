# frozen_string_literal: true

# Saves the snapped walking legs of one user and day into transit_walk_legs
# (derived data, like transit_segments). The day's previous legs are replaced
# in one transaction, except (review M1): a new leg for which the server
# rejected a trace never replaces an overlapping snapped leg (`valhalla` or
# `mixed`); the old one stays. Points are only referenced by id.
class Gtfs::Walk::LegWriter
  GOOD_SOURCES = %w[valhalla mixed].freeze

  # `valhalla`, `mixed` or `raw` for a Snapper result's parts
  def self.source_for(parts)
    sources = parts.map { |p| p[:source] }.uniq & %w[valhalla raw stationary]
    return 'raw' unless sources.include?('valhalla')

    sources.size > 1 ? 'mixed' : 'valhalla'
  end

  def initialize(user)
    @user = user
  end

  def call(outcomes, from_ts:, to_ts:)
    rows = outcomes.map { |o| row(o) }
    result = { 'deleted' => 0, 'created' => 0, 'kept' => 0 }
    TransitWalkLeg.transaction do
      existing = TransitWalkLeg.where(user_id: @user.id, started_at: from_ts...to_ts)
      kept = protected_legs(existing, outcomes)
      rows = rows.reject { |r| overlaps_any?(r, kept) }
      result['deleted'] = existing.where.not(id: kept.map(&:id)).delete_all
      if rows.any?
        ids = TransitWalkLeg.insert_all!(rows, returning: :id).rows.flatten
        TransitWalkLeg.refresh_drawn!(ids) # stored geometry for the zone check (review K-new-1)
        TransitWalkLeg.refresh_covered!(ids) # what the map's Tracks tiles leave out (docs/atlas.md)
      end
      result['created'] = rows.size
      result['kept'] = kept.size
    end
    result
  end

  private

  def row(outcome)
    leg = outcome.leg
    now = Time.current
    {
      user_id: @user.id, started_at: leg.start_ts, ended_at: leg.end_ts,
      point_count: leg.points.size, point_ids: leg.points.map(&:id),
      ride_ids: Array(leg.adjacent_rides).filter_map { |ride| ride[2] }.uniq,
      raw_distance_m: leg.distance.round(1), distance_m: outcome.result.stats.dig('metrics', 'drawn_m'),
      source: self.class.source_for(outcome.result.parts), parts: outcome.result.parts,
      stats: outcome.result.stats.merge('version' => Gtfs::Walk::Config::VERSION),
      created_at: now, updated_at: now
    }
  end

  def errored?(outcome) = outcome.result.stats['valhalla_errors'].to_i.positive?

  def protected_legs(existing, outcomes)
    errored = outcomes.select { |o| errored?(o) }
    return [] if errored.empty?

    existing.where(source: GOOD_SOURCES).to_a.select do |leg|
      errored.any? { |o| o.leg.start_ts <= leg.ended_at && o.leg.end_ts >= leg.started_at }
    end
  end

  def overlaps_any?(row, legs)
    legs.any? { |leg| row[:started_at] <= leg.ended_at && row[:ended_at] >= leg.started_at }
  end
end
