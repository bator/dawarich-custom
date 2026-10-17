# frozen_string_literal: true

require 'net/http'

# Minimal Discord REST client (API v10) for the transit bot. The token goes
# only into the Authorization header; errors never include it.
class Gtfs::Discord::Client
  API = 'https://discord.com/api/v10'
  USER_AGENT = 'DiscordBot (https://github.com/Freika/dawarich, 1.0) dawarich-transit'
  TIMEOUT = 10

  # A file sent with a message (multipart/form-data, files[n]).
  Upload = Struct.new(:filename, :data, :content_type)

  class Error < StandardError
    attr_reader :status

    def initialize(message, status: nil)
      super(message)
      @status = status
    end
  end

  class RateLimited < Error
    attr_reader :retry_after

    def initialize(retry_after)
      super("Discord rate limit, retry after #{retry_after}s", status: 429)
      @retry_after = retry_after
    end
  end

  def initialize(token: Gtfs::Discord::Config.token)
    raise ArgumentError, 'DISCORD_BOT_TOKEN is not set' if token.blank?

    @token = token
  end

  # With files, the payload's `attachments` list them (id = position) unless
  # it already has one, and an embed can show them as attachment://<name>.
  # An edit with files replaces the message's earlier attachments.
  def post_message(channel_id, payload, files: [])
    request(:post, "/channels/#{id!(channel_id)}/messages", payload, files)
  end

  def edit_message(channel_id, message_id, payload, files: [])
    request(:patch, "/channels/#{id!(channel_id)}/messages/#{id!(message_id)}", payload, files)
  end

  # Answer to a button click (must happen within 3 s of the click).
  def interaction_callback(interaction_id, interaction_token, payload)
    raise ArgumentError, 'invalid interaction token' unless interaction_token.to_s.match?(/\A[\w.-]+\z/)

    request(:post, "/interactions/#{id!(interaction_id)}/#{interaction_token}/callback", payload)
  end

  # Follow-up message after a deferred answer (e.g. an ephemeral error);
  # the interaction token stays valid for 15 minutes.
  def followup(application_id, interaction_token, payload)
    raise ArgumentError, 'invalid interaction token' unless interaction_token.to_s.match?(/\A[\w.-]+\z/)

    request(:post, "/webhooks/#{id!(application_id)}/#{interaction_token}", payload)
  end

  def message(channel_id, message_id)
    request(:get, "/channels/#{id!(channel_id)}/messages/#{id!(message_id)}")
  end

  # The bot's own user.
  def me
    request(:get, '/users/@me')
  end

  def gateway_url
    request(:get, '/gateway/bot').fetch('url')
  end

  private

  def id!(value)
    value.to_s.match?(/\A\d+\z/) ? value.to_s : raise(ArgumentError, 'Discord ids are numeric')
  end

  def request(method, path, payload = nil, files = [])
    uri = URI("#{API}#{path}")
    req = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
    req['Authorization'] = "Bot #{@token}"
    req['User-Agent'] = USER_AGENT
    if files.present?
      boundary = "dawarich-#{SecureRandom.hex(12)}"
      req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
      req.body = multipart(boundary, payload || {}, files)
    elsif payload
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(payload)
    end
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT,
read_timeout: TIMEOUT) do |http|
      http.request(req)
    end
    handle(response, method, path)
  end

  def multipart(boundary, payload, files)
    payload = payload.merge(attachments: files.each_with_index.map { |f, i| { id: i, filename: f.filename } }) \
      unless payload.key?(:attachments)
    body = String.new(encoding: Encoding::BINARY)
    body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"payload_json\"\r\n" \
            "Content-Type: application/json\r\n\r\n#{JSON.generate(payload)}\r\n".b
    files.each_with_index do |file, i|
      name = file.filename.to_s.gsub(/[^\w.-]/, '_')
      body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"files[#{i}]\"; filename=\"#{name}\"\r\n" \
              "Content-Type: #{file.content_type || 'application/octet-stream'}\r\n\r\n".b
      body << file.data.to_s.b << "\r\n".b
    end
    body << "--#{boundary}--\r\n".b
  end

  def handle(response, method, path)
    code = response.code.to_i
    body = response.body.to_s
    raise RateLimited, retry_after(response, body) if code == 429
    if code >= 400
      raise Error.new("Discord #{method.upcase} #{redact(path)} failed: #{code} #{body.truncate(200)}",
                      status: code)
    end

    body.empty? ? {} : JSON.parse(body)
  end

  def retry_after(response, body)
    (JSON.parse(body)['retry_after'] if body.present?) || response['Retry-After']&.to_f || 5.0
  rescue JSON::ParserError
    response['Retry-After']&.to_f || 5.0
  end

  # interaction tokens are secrets as well
  def redact(path)
    path.sub(%r{(/(?:interactions|webhooks)/\d+/)[^/]+}, '\1[token]')
  end
end
