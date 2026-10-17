# frozen_string_literal: true

require 'net/http'
require 'digest'

# Downloads a feed zip to a Tempfile (spec 7.1): conditional request
# (If-None-Match / If-Modified-Since), streamed to disk with a size limit and
# SHA-256, max 5 redirects, every hop re-checked by Gtfs::UrlGuard.
# Net::HTTP is used instead of Faraday so that each redirect target can be
# validated and only the final 200 body is written to the file.
#
# The caller owns the returned tempfile and must call `tempfile.close!`.
class Gtfs::FeedDownloader
  class Error < StandardError; end
  class HttpError < Error; end
  class TooLarge < Error; end
  class ConfigError < Error; end

  MAX_BYTES = ENV.fetch('GTFS_MAX_DOWNLOAD_BYTES', 1_073_741_824).to_i
  MAX_REDIRECTS = 5
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 120
  # Total time budget for one download (a slow server could otherwise keep the
  # job busy for read_timeout per chunk until the size limit).
  DEADLINE_SECONDS = ENV.fetch('GTFS_DOWNLOAD_DEADLINE_SECONDS', 1800).to_i

  Result = Struct.new(:status, :tempfile, :etag, :last_modified, :sha256, :bytes, keyword_init: true)

  def initialize(feed, max_bytes: MAX_BYTES, deadline_seconds: DEADLINE_SECONDS)
    @feed = feed
    @max_bytes = max_bytes
    @deadline_seconds = deadline_seconds
  end

  def call
    raise ConfigError, "feed #{@feed.key} has no source URL" if @feed.source_url.blank?

    @deadline = monotonic + @deadline_seconds
    auth = Gtfs::FeedRegistry.auth_for(@feed.key)
    uri = with_query(URI.parse(@feed.source_url), auth[:query])
    conditional = conditional_allowed?

    (MAX_REDIRECTS + 1).times do
      ip = Gtfs::UrlGuard.check!(uri)
      result = request(uri, ip, auth, conditional)
      return result unless result.is_a?(URI::Generic)

      # Credentials only go to the original origin (scheme + host + port), so
      # they are never sent to another host or over a downgraded connection.
      auth = {} unless same_origin?(uri, result)
      uri = result
      conditional = false
    end
    raise HttpError, "too many redirects (> #{MAX_REDIRECTS})"
  rescue URI::InvalidURIError => e
    raise ConfigError, "invalid feed URL: #{e.message}"
  end

  private

  # Cache validators belong to the last *successful* import. Without one (never
  # imported, last import failed or was interrupted) always fetch the full file.
  def conditional_allowed?
    @feed.imported? && @feed.idle?
  end

  def same_origin?(from, to)
    from.scheme == to.scheme && from.host == to.host && from.port == to.port
  end

  def request(uri, ip, auth, conditional)
    # No proxy (third argument nil): the connection must go to the IP that
    # Gtfs::UrlGuard checked, an http(s)_proxy from the environment would
    # bypass that pinning.
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.ipaddr = ip
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    req = Net::HTTP::Get.new(uri)
    req['User-Agent'] = Gtfs::FeedRegistry.user_agent_for(@feed.key)
    req['Accept'] = 'application/zip, application/octet-stream, */*'
    if conditional
      req['If-None-Match'] = @feed.etag if @feed.etag.present?
      req['If-Modified-Since'] = @feed.last_modified_remote.httpdate if @feed.last_modified_remote
    end
    auth[:headers]&.each { |k, v| req[k] = v }
    req.basic_auth(*auth[:basic]) if auth[:basic]

    outcome = nil
    http.request(req) do |response|
      outcome =
        case response
        when Net::HTTPNotModified
          Result.new(status: :not_modified)
        when Net::HTTPRedirection
          location = response['location'] or raise HttpError, "redirect without Location (#{response.code})"
          URI.join(uri.to_s, location)
        when Net::HTTPOK
          save_body(response)
        else
          raise HttpError, "unexpected HTTP status #{response.code}"
        end
    end
    outcome
  end

  def save_body(response)
    declared = response['content-length'].to_i
    raise TooLarge, "feed is too large (#{declared} bytes)" if declared > @max_bytes

    tmp = Tempfile.new(["gtfs-#{@feed.key}", '.zip'], Gtfs.tmp_dir, binmode: true)
    digest = Digest::SHA256.new
    bytes = 0
    response.read_body do |chunk|
      bytes += chunk.bytesize
      raise TooLarge, "feed is too large (> #{@max_bytes} bytes)" if bytes > @max_bytes
      raise HttpError, "download took longer than #{@deadline_seconds}s" if monotonic > @deadline

      tmp.write(chunk)
      digest.update(chunk)
    end
    tmp.flush
    Result.new(status: :downloaded, tempfile: tmp, etag: response['etag'],
               last_modified: parse_http_date(response['last-modified']), sha256: digest.hexdigest, bytes:)
  rescue StandardError
    tmp&.close!
    raise
  end

  def with_query(uri, query)
    return uri if query.blank?

    params = URI.decode_www_form(uri.query.to_s) + query.to_a
    uri.dup.tap { |u| u.query = URI.encode_www_form(params) }
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def parse_http_date(value)
    Time.httpdate(value) if value.present?
  rescue ArgumentError
    nil
  end
end
