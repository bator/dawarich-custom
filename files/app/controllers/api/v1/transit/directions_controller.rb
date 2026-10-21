# frozen_string_literal: true

# The map's directions panel (docs/atlas.md): Atlas place search and routes,
# proxied so the browser needs no Atlas access and the user's API key guards
# it like every other map request.
class Api::V1::Transit::DirectionsController < Api::V1::Transit::BaseController
  before_action :require_atlas

  # GET /api/v1/transit/directions?from=lat,lon&to=lat,lon&mode=car|bike|walk|transit
  #   [&time=ISO 8601&arrive_by=true] (time and arrive_by: transit only)
  def show
    result = Atlas::Directions.new.call(from: point(:from), to: point(:to), mode: params[:mode].to_s,
                                        time: time_param, arrive_by: params[:arrive_by] == 'true')
    render json: result
  rescue ArgumentError => e
    unprocessable(e)
  rescue Gtfs::Walk::BaseClient::Unavailable => e
    # Atlas passes a routing failure of Valhalla on as 502 UPSTREAM_ERROR
    e.message.include?('UPSTREAM_ERROR') ? no_route : atlas_unavailable(e)
  rescue Gtfs::Walk::BaseClient::Error
    no_route
  end

  # GET /api/v1/transit/directions/search?q=...[&lat=..&lon=..]
  def search
    query = params[:q].to_s.strip
    return render json: { results: [] } if query.length < 2

    data = Atlas::Client.new.search(query[0, 200], lat: coordinate(:lat), lon: coordinate(:lon)).fetch('data')
    results = Array(data).filter_map do |r|
      lat, lon = r.dig('coords', 'lat'), r.dig('coords', 'lon')
      next unless lat.is_a?(Numeric) && lon.is_a?(Numeric)

      { label: r['label'] || r['name'], name: r['name'], type: r['type'], lat:, lon: }
    end
    render json: { results: }
  rescue Gtfs::Walk::BaseClient::Error => e
    atlas_unavailable(e)
  end

  private

  def require_atlas
    return if Atlas::Config.enabled?

    render json: { error: 'atlas_disabled', message: Atlas::Config.url_problem }, status: :service_unavailable
  end

  def no_route
    render json: { error: 'no_route', message: 'No route between these points.' }, status: :unprocessable_content
  end

  def atlas_unavailable(error)
    Rails.logger.warn("[atlas] #{error.class}: #{error.message}")
    render json: { error: 'atlas_unavailable', message: 'Atlas did not answer. Try again later.' }, status: :service_unavailable
  end

  # "lat,lon" => [lat, lon]
  def point(name)
    lat, lon = params[name].to_s.split(',', 2).map { |v| Float(v.strip, exception: false) }
    raise ArgumentError, "#{name} must be lat,lon" unless lat&.between?(-90, 90) && lon&.between?(-180, 180)

    [lat, lon]
  end

  def coordinate(name) = Float(params[name].to_s, exception: false)

  def time_param
    value = params[:time].presence
    value ? Time.iso8601(value) : nil
  rescue ArgumentError
    raise ArgumentError, 'time must be ISO 8601'
  end
end
