# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

# HTTP and shared parsing for the two map-matching backends
# (Gtfs::Walk::AtlasClient, Gtfs::Walk::ValhallaClient). Both return the
# matched runs of a trace: consecutive input points that were matched onto one
# continuous path, each with its path geometry trimmed to the first/last
# matched position. Unmatched points and path breaks split runs; they are
# never bridged here.
#
# Errors (review K-1):
# - Error: the server answered properly but rejected this trace (Valhalla
#   400, Atlas 422); the caller keeps the recorded GPS for it;
# - Unavailable (an Error): no usable answer at all -- connection refused,
#   timeout, 5xx, 404, still busy after the retries, not JSON, too large,
#   broken geometry, the day's time budget used up. The caller stops asking
#   (circuit breaker) and writes nothing.
#
# Retries (review N5/N8): 429/503 up to twice (1-2 s apart; the server did
# not process the request). After a connection error a GET is repeated once,
# a POST only when it surely never reached the server (connect timeout) --
# never after a read timeout, so a slow match is not sent twice while the
# server is still working on it. With a budget (Gtfs::Walk::Breaker#remaining)
# no attempt starts and no read waits beyond the remaining time.
class Gtfs::Walk::BaseClient
  class Error < StandardError; end
  class Unavailable < Error; end

  Run = Struct.new(:first_index, :last_index, :coords, keyword_init: true)

  RETRY_STATUSES = %w[429 503].freeze
  MAX_BUSY_RETRIES = 2
  CONNECTION_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, EOFError].freeze
  POST_RETRY_ERRORS = [Net::OpenTimeout].freeze
  MIN_READ_TIMEOUT_SECS = 0.5
  HEALTH_LOCK = Mutex.new

  def self.build(url: Gtfs::Walk::Config.valhalla_url, api: Gtfs::Walk::Config.api, **)
    (api == 'valhalla' ? Gtfs::Walk::ValhallaClient : Gtfs::Walk::AtlasClient).new(url:, **)
  end

  # url => monotonic expiry of the last successful health check (per process)
  def self.health_cache
    Gtfs::Walk::BaseClient.instance_variable_get(:@health_cache) ||
      Gtfs::Walk::BaseClient.instance_variable_set(:@health_cache, {})
  end

  def self.reset_health_cache! = HEALTH_LOCK.synchronize { health_cache.clear }

  attr_reader :url
  # anything with #remaining (seconds left), e.g. the day's Gtfs::Walk::Breaker
  attr_accessor :budget

  def initialize(url:, open_timeout: Gtfs::Walk::Config::OPEN_TIMEOUT_SECS,
                 read_timeout: Gtfs::Walk::Config::READ_TIMEOUT_SECS,
                 max_bytes: Gtfs::Walk::Config::MAX_RESPONSE_BYTES, sleeper: ->(secs) { sleep(secs) })
    @url = url.to_s.chomp('/')
    @open_timeout = open_timeout
    @read_timeout = read_timeout
    @max_bytes = max_bytes
    @sleeper = sleeper
  end

  # Raises Unavailable unless the server is the expected one and ready
  # (review K2). A success is cached per process for HEALTH_CACHE_SECS.
  def healthy!
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return true if HEALTH_LOCK.synchronize { self.class.health_cache[@url].to_f > now }

    check_health!
    HEALTH_LOCK.synchronize { self.class.health_cache[@url] = now + Gtfs::Walk::Config::HEALTH_CACHE_SECS }
    true
  end

  # search_radius / gps_accuracy / breakage_distance for the whole request
  # (review K-3), from the median reported accuracy.
  def self.trace_options(points)
    c = Gtfs::Walk::Config
    accuracies = points.map { |p| p.accuracy.to_f }.select(&:positive?).sort
    accuracy = accuracies.empty? ? c::DEFAULT_ACCURACY_M : accuracies[accuracies.size / 2]
    {
      search_radius: radius_for(accuracy),
      gps_accuracy: accuracy.clamp(5.0, 100.0).round(1),
      breakage_distance: c::MAX_POINT_GAP_M.round
    }
  end

  def self.radius_for(accuracy)
    c = Gtfs::Walk::Config
    acc = accuracy.to_f.positive? ? accuracy.to_f : c::DEFAULT_ACCURACY_M
    (acc * c::RADIUS_FACTOR).clamp(c::RADIUS_MIN_M, c::RADIUS_MAX_M).round
  end

  def self.shape_point(point)
    entry = { lat: point.lat.to_f.round(7), lon: point.lon.to_f.round(7), time: point.ts.to_i }
    entry[:accuracy] = point.accuracy.to_f.round(1) if point.accuracy.to_f.positive?
    entry
  end

  # Valhalla encodes shapes with 6 decimals; a truncated string is a broken
  # answer, not a crash (review K-2).
  def self.decode_polyline6(str)
    coords = []
    index = 0
    lat = 0
    lon = 0
    while index < str.length
      lat_delta, index = decode_value(str, index)
      lon_delta, index = decode_value(str, index)
      lat += lat_delta
      lon += lon_delta
      coords << [lon / 1e6, lat / 1e6]
    end
    coords
  end

  def self.decode_value(str, index)
    shift = 0
    result = 0
    loop do
      byte = str.getbyte(index)
      raise Unavailable, 'truncated polyline in the answer' if byte.nil?

      byte -= 63
      raise Unavailable, 'invalid polyline in the answer' if byte.negative?

      index += 1
      result |= (byte & 0x1f) << shift
      shift += 5
      break if byte < 0x20
    end
    [result.odd? ? ~(result >> 1) : (result >> 1), index]
  end

  # Cuts the path to start at `head` and end at `tail` (both matched positions
  # on the path). Head is searched up to coordinate index `head_until`, tail
  # from index `tail_from` on (and after head): on an out-and-back walk the
  # way back ends next to the start, so the closest place to the tail on the
  # whole rest of the path would be near the head (review U9). The indexes are
  # the first/last matched edge's own shape range when the client knows them.
  def self.trim(coords, head, tail, head_until: nil, tail_from: nil)
    return coords if coords.size < 2

    projector = Gtfs::Matching::Geo.projector(coords.first[1])
    line = Gtfs::Matching::Geo::Polyline.new(coords, projector)
    return coords unless line.usable?

    head_max = head_until ? along_at(coords, projector, head_until) : Float::INFINITY
    head_along, = line.project(*projector.call(*head), to: head_max)
    tail_min = [head_along || 0.0, tail_from ? along_at(coords, projector, tail_from) : 0.0].max
    tail_along, = line.project(*projector.call(*tail), from: tail_min)
    return coords if head_along.nil? || tail_along.nil? || tail_along <= head_along

    cut(line, projector, head_along, tail_along)
  end

  # metres along coords up to coordinate index (as Polyline measures them)
  def self.along_at(coords, projector, index)
    last = index.clamp(0, coords.size - 1)
    coords[0..last].map { |lon, lat| projector.call(lon, lat) }
                   .each_cons(2).sum { |(ax, ay), (bx, by)| Math.hypot(bx - ax, by - ay) }
  end

  def self.cut(line, projector, from, to)
    kx = projector.call(1, 0)[0]
    ky = projector.call(0, 1)[1]
    inverse = ->(x, y) { [x / kx, y / ky] }
    out = [point_at(line, from, inverse)]
    line.cumulative.each_with_index do |along, i|
      out << inverse.call(line.xs[i], line.ys[i]) if along > from && along < to
    end
    out << point_at(line, to, inverse)
    out.map { |lon, lat| [lon.round(7), lat.round(7)] }.chunk_while { |a, b| a == b }.map(&:first)
  end

  def self.point_at(line, along, inverse)
    i = line.cumulative.bsearch_index { |c| c >= along } || (line.cumulative.size - 1)
    i = 1 if i.zero?
    seg = line.cumulative[i] - line.cumulative[i - 1]
    t = seg.positive? ? (along - line.cumulative[i - 1]) / seg : 0.0
    inverse.call(line.xs[i - 1] + (t * (line.xs[i] - line.xs[i - 1])),
                 line.ys[i - 1] + (t * (line.ys[i] - line.ys[i - 1])))
  end

  def self.usable_match?(matched)
    matched.is_a?(Hash) && %w[matched interpolated].include?(matched['type']) &&
      matched['lat'].is_a?(Numeric) && matched['lon'].is_a?(Numeric)
  end

  private

  def get_json(path)
    request(Net::HTTP::Get.new(endpoint(path).request_uri), path)
  end

  def post_json(path, body)
    req = Net::HTTP::Post.new(endpoint(path).request_uri, 'Content-Type' => 'application/json')
    req.body = JSON.generate(body)
    request(req, path)
  end

  def endpoint(path) = URI.join("#{@url}/", path.delete_prefix('/'))

  # Retries as described above; everything else goes straight to the caller
  # (its circuit breaker).
  def request(req, path, busy_retries: 0, reconnected: false)
    check_budget!(path)
    code, body, retry_after = perform(req, path)
    if RETRY_STATUSES.include?(code) && busy_retries < MAX_BUSY_RETRIES && pause(retry_after)
      return request(req, path, busy_retries: busy_retries + 1, reconnected:)
    end

    answer(code, body, path)
  rescue *CONNECTION_ERRORS => e
    raise Unavailable, "#{path}: #{e.class}: #{e.message}" if reconnected || !retryable?(req, e) || !pause(nil)

    request(req, path, busy_retries:, reconnected: true)
  end

  def retryable?(req, error)
    req.is_a?(Net::HTTP::Get) || POST_RETRY_ERRORS.any? { |klass| error.is_a?(klass) }
  end

  # Waits before a retry; false (no retry) when the budget would not allow it
  def pause(retry_after)
    secs = Float(retry_after.to_s, exception: false)
    secs = secs ? secs.clamp(1.0, 2.0) : 1.0 + rand
    left = remaining
    return false if left && left < secs + MIN_READ_TIMEOUT_SECS

    @sleeper.call(secs)
    true
  end

  def remaining = @budget&.remaining

  def check_budget!(path)
    left = remaining
    raise Unavailable, "#{path}: time budget used up" if left && left < MIN_READ_TIMEOUT_SECS
  end

  def read_timeout
    left = remaining
    left ? left.clamp(MIN_READ_TIMEOUT_SECS, @read_timeout) : @read_timeout
  end

  def perform(req, path)
    uri = endpoint(path)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = @open_timeout
    http.read_timeout = read_timeout
    http.max_retries = 0 # Net::HTTP would repeat a GET by itself (review U3); retries are ours
    http.request(req) do |response|
      return [response.code.to_s, read_limited(response, path), response['Retry-After']]
    end
  rescue Error, *CONNECTION_ERRORS
    raise
  rescue StandardError => e
    raise Unavailable, "#{path}: #{e.class}: #{e.message}"
  end

  def read_limited(response, path)
    body = +''
    response.read_body do |chunk|
      body << chunk
      raise Unavailable, "#{path}: answer larger than #{@max_bytes} bytes" if body.bytesize > @max_bytes
    end
    body
  end

  def answer(code, body, path)
    parsed = parse(body, code, path)
    return parsed if code.start_with?('2')

    message = error_message(parsed)
    raise Error, "#{path}: HTTP #{code}: #{message}".strip if rejected?(code, parsed)

    raise Unavailable, "#{path}: HTTP #{code}: #{message}".strip
  end

  def parse(body, code, path)
    parsed = JSON.parse(body.to_s)
    raise Unavailable, "#{path}: HTTP #{code}: not a JSON object" unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError
    raise Unavailable, "#{path}: HTTP #{code}: not JSON (#{body.to_s[0, 60].inspect})"
  end
end
