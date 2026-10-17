# frozen_string_literal: true

# Does a drawn walking leg touch a privacy zone? (review K2) Every part with
# coordinates is checked as the line that is drawn (or as one point), not
# vertex by vertex: a snapped line between two map nodes can cross a zone
# without a vertex inside it. The Ruby twin of TransitWalkLeg.zone_condition.
module Gtfs::Walk::ZoneCheck
  module_function

  # parts: Snapper parts or stored parts (symbol or string keys);
  # zones: [{ lon:, lat:, radius: }] (Users::PrivacyZones)
  def touches?(parts, zones)
    return false if zones.blank?

    Array(parts).any? do |part|
      next false unless part.is_a?(Hash) # stored parts are not checked on read

      coords = drawable(part[:coords] || part['coords'])
      coords.any? && zones.any? { |zone| near?(coords, zone) }
    end
  end

  # The coordinates that are drawn: like TransitWalkLeg.drawn_sql, a vertex
  # without a number is left out (review A-8-3: nil.to_f would draw a line
  # to 0,0 and miss a crossing).
  def drawable(coords)
    return [] unless coords.is_a?(Array)

    coords.select { |c| c.is_a?(Array) && !c[0].nil? && !c[1].nil? }
  end

  # => true when the line through coords comes within the zone's radius of
  # its centre.
  def near?(coords, zone)
    distance_m(coords, zone) <= zone[:radius].to_f
  end

  # Metres from the zone's centre to the line through coords (local metric
  # projection, exact enough at zone scale: within ~2 m of PostGIS'
  # geodesic distance, so a line right at the radius may be flagged
  # differently by the two; the SQL decides what is shown).
  def distance_m(coords, zone)
    coords = drawable(coords)
    return Float::INFINITY if coords.empty?

    lon = zone[:lon].to_f
    lat = zone[:lat].to_f
    projector = Gtfs::Matching::Geo.projector(lat)
    line = Gtfs::Matching::Geo::Polyline.new(coords.map { |c| [c[0].to_f, c[1].to_f] }, projector)
    unless line.usable?
      first = coords.first
      return Gtfs::Matching::Geo.haversine(first[0].to_f, first[1].to_f, lon, lat)
    end

    line.project(*projector.call(lon, lat)).last
  end
end
