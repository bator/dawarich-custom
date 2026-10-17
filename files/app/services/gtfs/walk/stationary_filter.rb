# frozen_string_literal: true

# Splits a walking leg into moving pieces and stationary clouds (standing at a
# stop, waiting at a light, a shop). Valhalla draws loops and spikes through a
# cloud of fixes a few metres apart, so clouds are never sent to it; they stay
# as recorded. Moving pieces are thinned (MIN_SPACING_M) before the request.
class Gtfs::Walk::StationaryFilter
  Piece = Struct.new(:kind, :points, keyword_init: true) do
    def stationary? = kind == :stationary
  end

  def initialize(points, radius_m: Gtfs::Walk::Config::STATIONARY_RADIUS_M,
                 min_secs: Gtfs::Walk::Config::STATIONARY_MIN_SECS)
    @points = points
    @radius = radius_m
    @min_secs = min_secs
  end

  def call
    pieces = []
    moving = []
    i = 0
    while i < @points.size
      j = cloud_end(i)
      if @points[j].ts - @points[i].ts >= @min_secs
        unless moving.empty?
          moving << @points[i] # the moving piece ends where the cloud starts
          pieces << Piece.new(kind: :move, points: moving)
        end
        pieces << Piece.new(kind: :stationary, points: @points[i..j])
        moving = [@points[j]] # ... and the next one starts where it ends
        i = j + 1
      else
        moving << @points[i]
        i += 1
      end
    end
    pieces << Piece.new(kind: :move, points: moving) if moving.size >= 2
    pieces
  end

  # Drops points closer than min_spacing to the previous kept point; the last
  # point is always kept.
  def self.thin(points, min_spacing: Gtfs::Walk::Config::MIN_SPACING_M)
    return points.dup if points.size <= 2

    kept = [points.first]
    points[1...-1].each do |p|
      kept << p if Gtfs::Matching::Geo.haversine(kept.last.lon, kept.last.lat, p.lon, p.lat) >= min_spacing
    end
    kept << points.last
    kept
  end

  private

  # Last index of the cloud that starts at i: every following point stays
  # within the radius of the cloud's first point. (A running centroid would
  # follow a slow walk and swallow it.)
  def cloud_end(start)
    anchor = @points[start]
    j = start
    while j + 1 < @points.size
      nxt = @points[j + 1]
      break if Gtfs::Matching::Geo.haversine(anchor.lon, anchor.lat, nxt.lon, nxt.lat) > @radius

      j += 1
    end
    j
  end
end
