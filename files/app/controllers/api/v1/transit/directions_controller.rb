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
    # Atlas passes any non-2xx answer of Valhalla or MOTIS on as 502
    # UPSTREAM_ERROR "upstream returned <status>: ...": a 4xx there is "no
    # route" (Valhalla 400, error 442), a 5xx or no status a failure
    e.message.match?(/UPSTREAM_ERROR upstream returned 4\d\d\b/) ? no_route : atlas_unavailable(e)
  rescue Gtfs::Walk::BaseClient::Error => e
    # Atlas refused our parameters (400 MISSING_PARAM, 422 VALIDATION_ERROR)
    atlas_rejected(e)
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
    log_atlas_error(error)
    render json: { error: 'atlas_unavailable', message: 'Atlas did not answer. Try again later.' }, status: :service_unavailable
  end

  def atlas_rejected(error)
    log_atlas_error(error)
    render json: { error: 'atlas_rejected', message: 'Atlas rejected the request.' }, status: :unprocessable_content
  end

  # The message names the request path; its query (the searched address, the
  # route's ends) stays out of the log.
  def log_atlas_error(error)
    Rails.logger.warn("[atlas] #{error.class}: #{error.message.gsub(/\?[^\s:]+/, '?[query]')}")
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
