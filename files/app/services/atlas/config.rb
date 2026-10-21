# frozen_string_literal: true

# Dawarich Atlas for the map (docs/atlas.md): directions by car, bike and on
# foot (Valhalla), public transport (MOTIS) and the place search of the
# directions panel, proxied by Api::V1::Transit::DirectionsController so the
# browser never talks to Atlas itself. Reverse geocoding and the map's own
# place search go through Atlas when PHOTON_API_HOST points at its Photon
# pass-through (`host:port/api/v1/photon`), with no code of ours.
module Atlas::Config
  module_function

  # ATLAS_API_URL, else the walk snap's Atlas (GTFS_WALK_VALHALLA_URL with
  # GTFS_WALK_VALHALLA_API=atlas); nil when neither is set.
  def api_url
    url = ENV.fetch('ATLAS_API_URL', '').to_s.strip.chomp('/')
    return url unless url.empty?

    Gtfs::Walk::Config.api == 'atlas' ? Gtfs::Walk::Config.valhalla_url : nil
  end

  # nil when the URL can be used, else why not. The same rule as the walk
  # snap: a private address or a host in GTFS_WALK_VALHALLA_ALLOWED_HOSTS, so
  # the places a user looks up never go to a random host.
  def url_problem
    url = api_url
    return 'ATLAS_API_URL is not set' if url.nil?

    Gtfs::Walk::Config.url_problem(url)
  end

  def enabled? = url_problem.nil?

  # The Atlas web UI for the navbar link (ATLAS_UI_URL); unset hides the link.
  def ui_url = ENV['ATLAS_UI_URL'].to_s.strip.presence
end
