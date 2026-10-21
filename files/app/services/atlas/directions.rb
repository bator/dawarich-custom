# frozen_string_literal: true

# Directions for the map panel (docs/atlas.md): asks Atlas and turns its
# answer into what the map draws, GeoJSON (one LineString per leg, [lon, lat])
# with the times and names the panel lists. Modes: car, bike, walk (Valhalla)
# and transit (MOTIS, walking legs included).
class Atlas::Directions
  MODES = { 'car' => 'auto', 'bike' => 'bicycle', 'walk' => 'pedestrian', 'transit' => nil }.freeze

  def initialize(client: Atlas::Client.new)
    @client = client
  end

  # from / to: [lat, lon]; time: a Time (transit only) => Hash for the JSON
  def call(from:, to:, mode:, time: nil, arrive_by: false)
    raise ArgumentError, "mode must be one of #{MODES.keys.join('/')}" unless MODES.key?(mode)

    mode == 'transit' ? transit(from, to, time, arrive_by) : road(from, to, mode)
  end

  private

  def road(from, to, mode)
    data = @client.route(from:, to:, mode: MODES.fetch(mode)).fetch('data')
    coords = Array(data['legs']).flat_map { |leg| decode(leg['shape']) }
    summary = data['summary'] || {}
    route = { duration_s: summary['time'].to_f.round, distance_m: (summary['length'].to_f * 1000).round }
    { mode:, routes: [route.merge(geojson: collection([feature(coords, mode:)]))] }
  end

  def transit(from, to, time, arrive_by)
    data = @client.transit(from:, to:, time:, arrive_by:).fetch('data')
    routes = Array(data['itineraries']).map do |itinerary|
      legs = Array(itinerary['legs']).map { |leg| transit_leg(leg) }
      {
        duration_s: itinerary['duration'].to_i, start: itinerary['start_time'], end: itinerary['end_time'],
        transfers: itinerary['transfers'].to_i, walk_m: itinerary['walk_distance'].to_f.round,
        distance_m: legs.sum { |l| l[:distance_m].to_i },
        legs: legs.map { |l| l.except(:coords) },
        geojson: collection(legs.map { |l| feature(l[:coords], mode: l[:mode], line: l[:line]) })
      }
    end
    { mode: 'transit', routes: }
  end

  def transit_leg(leg)
    {
      mode: leg['mode'].to_s.downcase, line: leg['route_name'], headsign: leg['headsign'],
      agency: leg['agency_name'], from: stop(leg['from']), to: stop(leg['to']),
      start: leg['start_time'], end: leg['end_time'], duration_s: leg['duration'].to_i,
      distance_m: leg['distance'].to_f.round, coords: decode(leg['shape'])
    }
  end

  def stop(place)
    place ||= {}
    name = place['name'].to_s
    { name: (%w[START END].include?(name) ? nil : name.presence), lat: place['lat'], lon: place['lon'] }
  end

  def decode(shape) = shape.is_a?(String) ? Gtfs::Walk::BaseClient.decode_polyline6(shape) : []

  def feature(coords, **properties)
    { type: 'Feature', properties: properties.compact,
      geometry: { type: 'LineString', coordinates: coords.map { |lon, lat| [lon.round(6), lat.round(6)] } } }
  end

  def collection(features) = { type: 'FeatureCollection', features: features.reject { |f| f[:geometry][:coordinates].size < 2 } }
end
