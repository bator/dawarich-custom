# frozen_string_literal: true

require 'net/http'

# Raster map tiles (PNG, {z}/{x}/{y}) for the Discord map image, cached on
# disk. Follows the OpenStreetMap tile usage policy: an identifying
# User-Agent, tiles kept for GTFS_MAP_TILE_CACHE_DAYS (at least 7) and
# fetched one at a time, only the handful one image needs. A local tile
# server can be used instead through GTFS_MAP_TILE_URL.
class Gtfs::Discord::TileSource
  PNG_SIGNATURE = "\x89PNG".b
  TIMEOUT = 5

  def initialize(url: Gtfs::Discord::Config.tile_url, user_agent: Gtfs::Discord::Config.tile_user_agent,
                 cache_dir: Gtfs::Discord::Config.tile_cache_dir, cache_days: Gtfs::Discord::Config.tile_cache_days,
                 logger: Rails.logger)
    @url = url
    @user_agent = user_agent
    @cache_dir = Pathname(cache_dir)
    @max_age = cache_days.days
    @logger = logger
  end

  # PNG bytes of the tile, or nil (the image then shows a plain background).
  def fetch(zoom, tile_x, tile_y)
    path = @cache_dir.join(zoom.to_s, tile_x.to_s, "#{tile_y}.png")
    return path.binread if fresh?(path)

    blob = download(zoom, tile_x, tile_y)
    return store(path, blob) if blob

    path.exist? ? path.binread : nil
  end

  private

  def fresh?(path)
    path.exist? && path.mtime > @max_age.ago
  end

  def download(zoom, tile_x, tile_y)
    uri = URI(@url.gsub('{z}', zoom.to_s).gsub('{x}', tile_x.to_s).gsub('{y}', tile_y.to_s))
    return nil unless uri.is_a?(URI::HTTP)

    request = Net::HTTP::Get.new(uri)
    request['User-Agent'] = @user_agent
    request['Accept'] = 'image/png'
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                   open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.request(request)
    end
    body = response.body.to_s.b
    return body if response.code == '200' && body.start_with?(PNG_SIGNATURE)

    @logger.warn("[GTFS discord] map tile #{zoom}/#{tile_x}/#{tile_y}: HTTP #{response.code}")
    nil
  rescue StandardError => e
    @logger.warn("[GTFS discord] map tile #{zoom}/#{tile_x}/#{tile_y}: #{e.class}: #{e.message}")
    nil
  end

  def store(path, blob)
    FileUtils.mkdir_p(path.dirname)
    tmp = path.sub_ext(".#{SecureRandom.hex(4)}.tmp")
    tmp.binwrite(blob)
    File.rename(tmp, path)
    blob
  rescue SystemCallError => e
    @logger.warn("[GTFS discord] map tile cache: #{e.message}")
    blob
  end
end
