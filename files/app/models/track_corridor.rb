# frozen_string_literal: true

# A frequent route of a user: the median line of the trips of one cluster
# (Corridors::Builder). Rebuilt weekly as a whole per user.
class TrackCorridor < ApplicationRecord
  belongs_to :user

  # The line in pieces for the map: [[[[lon, lat], ...], filled?], ...];
  # filled = routed through a gap (Corridors::GapFiller). `filled` holds metres
  # along the line as the builder measured it: cut here at the same shares of
  # length_m.
  def parts
    coords = path.points.map { |p| [p.x, p.y] }
    ranges = Array(filled).select { |r| r.is_a?(Array) && r.size == 2 }.map { |a, b| [a.to_f, b.to_f] }.sort
    return [[coords, false]] if ranges.empty? || coords.size < 2

    g = Corridors::Geometry
    frame = g::Frame.new(*coords.first)
    xy = coords.map { |lon, lat| frame.xy(lon, lat) }
    s = g.lengths(xy)
    scale = length_m.to_f.positive? ? s.last / length_m.to_f : 1.0
    out = []
    cursor = 0.0
    ranges.each do |from, to|
      from = (from * scale).clamp(cursor, s.last)
      to = (to * scale).clamp(from, s.last)
      out << [g.slice(xy, s, cursor, from), false] if from > cursor
      out << [g.slice(xy, s, from, to), true] if to > from
      cursor = to
    end
    out << [g.slice(xy, s, cursor, s.last), false] if s.last > cursor
    out.map { |part, routed| [part.map { |x, y| frame.lonlat(x, y) }, routed] }
  end

  def stretch_m(ranges) = Array(ranges).sum { |a, b| b.to_f - a.to_f }.round
end
