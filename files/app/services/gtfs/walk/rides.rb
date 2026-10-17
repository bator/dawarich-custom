# frozen_string_literal: true

# The rides walking legs are cut around and attached to (review M5): the
# user's saved, not rejected transit_segments that start within the day
# (+/- DAY_BUFFER_SECS, like the points). Gtfs::MatchDay (after saving) and
# gtfs:walk_snap both use this list. => [[started_at, ended_at, id], ...]
module Gtfs::Walk::Rides
  module_function

  def saved(user, from_ts, to_ts)
    buffer = Gtfs::Config::DAY_BUFFER_SECS
    TransitSegment.where(user_id: user.id).where.not(status: :rejected)
                  .where(started_at: (from_ts - buffer)...(to_ts + buffer))
                  .order(:started_at).pluck(:started_at, :ended_at, :id)
  end

  # A dry match saves nothing: its matches stand in (no ids, nothing is
  # written in a dry run anyway).
  def from_matches(matches)
    matches.map { |m| [m.started_at, m.ended_at, nil] }
  end
end
