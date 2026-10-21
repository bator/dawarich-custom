# frozen_string_literal: true

# GET calls of the Atlas public API (docs/atlas.md) for the map's directions
# panel. Inherits the walk snap client's HTTP: timeouts, retries of 429/503,
# answer size limit and errors (Error: Atlas rejected the request, 400/422;
# Unavailable: no usable answer).
class Atlas::Client < Gtfs::Walk::AtlasClient
  ROAD_MODES = %w[auto bicycle pedestrian].freeze

  def initialize(url: Atlas::Config.api_url, **)
    super
  end

  # Places and addresses (Photon): `data` is a list of results with label,
  # name, type and coords (lat, lon); lat/lon bias the results towards that point.
  def search(query, lat: nil, lon: nil, limit: 6)
    get_query('/api/v1/search', q: query, lat:, lon:, limit:)
  end

  # A Valhalla route: `data` has summary (length km, time s) and legs with a
  # polyline6 shape.
  def route(from:, to:, mode:)
    raise ArgumentError, "mode must be one of #{ROAD_MODES.join('/')}" unless ROAD_MODES.include?(mode)

    get_query('/api/v1/route', from: coords(from), to: coords(to), mode:)
  end

  # MOTIS itineraries: `data.itineraries`, legs with mode, route_name,
  # headsign, stops, times and a polyline6 shape. `time` is when to leave, or
  # when to arrive with arrive_by.
  def transit(from:, to:, time: nil, arrive_by: false, num: 3)
    get_query('/api/v1/transit', from: coords(from), to: coords(to), time: time&.iso8601,
                                 arrive_by: (arrive_by ? 'true' : nil), num:)
  end

  private

  def get_query(path, params) = get_json("#{path}?#{URI.encode_www_form(params.compact)}")

  def coords(point) = "#{Float(point[0]).round(6)},#{Float(point[1]).round(6)}"
end
