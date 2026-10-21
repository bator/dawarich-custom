# frozen_string_literal: true

require 'openssl'
require 'socket'
require 'websocket/driver'

# Gateway (websocket) connection of the transit bot: receives the button
# clicks (INTERACTION_CREATE) without a public HTTP endpoint, so the instance
# needs no open port. Run with `bin/rails gtfs:discord_bot` (one process).
#
# Only what the buttons need: HELLO -> IDENTIFY (no intents, interactions
# arrive anyway) or RESUME, heartbeats, and dispatch of INTERACTION_CREATE.
# Robustness (review H6):
# - every reconnect waits with exponential backoff and jitter (1-2 s, 2-4 s,
#   ... up to MAX_BACKOFF); a connection that reached READY/RESUMED starts
#   the backoff again from the beginning;
# - RECONNECT, a resumable INVALID_SESSION and most closes RESUME the
#   session (missed clicks are replayed by Discord); close codes 4007/4009
#   and a non-resumable INVALID_SESSION identify again;
# - fatal close codes (4004 bad token, 4010-4014 bad shard/version/intents)
#   stop the bot with a clear log line instead of reconnecting forever (the
#   rake task then exits with status 1);
# - the heartbeat thread and the read loop write to the socket under one
#   mutex.
# A click is answered first (deferred update, within Discord's 3 s), then
# reviewed, then the message is edited once (review H7).
class Gtfs::Discord::Gateway
  OP_DISPATCH = 0
  OP_HEARTBEAT = 1
  OP_IDENTIFY = 2
  OP_RESUME = 6
  OP_RECONNECT = 7
  OP_INVALID_SESSION = 9
  OP_HELLO = 10
  OP_HEARTBEAT_ACK = 11
  MAX_BACKOFF = 300
  FATAL_CLOSE_CODES = [4004, 4010, 4011, 4012, 4013, 4014].freeze
  NEW_SESSION_CLOSE_CODES = [4007, 4009].freeze

  class Reconnect < StandardError
    def initialize(message = nil, resume: true)
      super(message)
      @resume = resume
    end

    def resume?
      @resume
    end
  end

  class Fatal < StandardError; end

  def initialize(client: Gtfs::Discord::Client.new, handler: Gtfs::Discord::InteractionHandler.new,
                 token: Gtfs::Discord::Config.token, logger: Rails.logger, refresher: nil,
                 sleeper: ->(seconds) { sleep(seconds) }, random: Random.new)
    @client = client
    @handler = handler
    @refresher = refresher || method(:refresh_in_background)
    @token = token
    @logger = logger
    @sleeper = sleeper
    @random = random
    @write_lock = Mutex.new
    @stopped = false
    @sequence = nil
    @acked = true
  end

  # Returns false when stopped by a fatal close code, true on #stop.
  def run
    attempts = 0
    until @stopped
      begin
        @ready = false
        connect_and_listen
      rescue Fatal => e
        @logger.error("[GTFS discord] gateway closed for good, bot stops: #{e.message} " \
                      '(check DISCORD_BOT_TOKEN and the bot application)')
        Gtfs::Discord::BotStatus.update!(:fatal, message: e.message, ttl: 1.day)
        @fatal = e
        @stopped = true
      rescue Reconnect => e
        forget_session unless e.resume?
        attempts = 0 if @ready
        wait(attempts += 1, "reconnecting (#{e.resume? && resumable? ? 'resume' : 'new session'}): #{e.message}")
      rescue StandardError => e
        attempts = 0 if @ready
        wait(attempts += 1, "gateway error: #{e.class}: #{e.message}")
      end
    end
    @fatal.nil?
  end

  def stop
    @stopped = true
    @socket&.close
  end

  # Seconds to wait before connection attempt number `attempt` (1, 2, ...).
  def backoff(attempt)
    base = [2**(attempt - 1), MAX_BACKOFF].min
    [base * (1 + @random.rand), MAX_BACKOFF].min
  end

  # Raises Fatal or Reconnect for a websocket close code.
  def closed!(code, reason)
    message = "closed #{code} #{reason}".strip
    raise Fatal, message if FATAL_CLOSE_CODES.include?(code.to_i)

    raise Reconnect.new(message, resume: !NEW_SESSION_CLOSE_CODES.include?(code.to_i))
  end

  # One gateway payload (Hash). Returns the payloads to send back; the
  # websocket loop sends them. Raises Reconnect when the connection must be
  # replaced.
  def handle(payload)
    @sequence = payload['s'] if payload['s']
    case payload['op']
    when OP_HELLO
      @heartbeat_interval = payload.dig('d', 'heartbeat_interval').to_f / 1000
      @acked = true
      [resumable? ? resume : identify]
    when OP_HEARTBEAT then [heartbeat]
    when OP_HEARTBEAT_ACK
      @acked = true
      Gtfs::Discord::BotStatus.beat!
      []
    when OP_RECONNECT then raise Reconnect, 'server asked to reconnect'
    when OP_INVALID_SESSION then raise Reconnect.new('invalid session', resume: payload['d'] == true)
    when OP_DISPATCH then dispatch(payload['t'], payload['d'] || {})
    else []
    end
  end

  def heartbeat
    { op: OP_HEARTBEAT, d: @sequence }
  end

  # Called every heartbeat interval: false means the last one was not ACKed
  # (zombie connection, reconnect).
  def heartbeat_due!
    return false unless @acked

    @acked = false
    true
  end

  def resumable?
    @session_id.present? && !@sequence.nil?
  end

  attr_reader :sequence, :session_id, :heartbeat_interval, :resume_url, :fatal

  private

  def identify
    { op: OP_IDENTIFY,
      d: { token: @token, intents: 0, properties: { os: 'linux', browser: 'dawarich', device: 'dawarich' } } }
  end

  def resume
    { op: OP_RESUME, d: { token: @token, session_id: @session_id, seq: @sequence } }
  end

  def forget_session
    @session_id = nil
    @sequence = nil
    @resume_url = nil
  end

  def wait(attempt, message)
    delay = backoff(attempt)
    @logger.warn("[GTFS discord] #{message}; next attempt in #{delay.round(1)} s")
    Gtfs::Discord::BotStatus.update!(:reconnecting, message:) unless @stopped
    @sleeper.call(delay) unless @stopped
  end

  def dispatch(type, data)
    case type
    when 'READY'
      @session_id = data['session_id']
      @resume_url = data['resume_gateway_url']
      @ready = true
      @logger.info("[GTFS discord] connected as #{data.dig('user', 'username')}")
      Gtfs::Discord::BotStatus.connected!(data.dig('user', 'username'))
    when 'RESUMED'
      @ready = true
      @logger.info('[GTFS discord] session resumed')
      Gtfs::Discord::BotStatus.update!(:connected)
    when 'INTERACTION_CREATE'
      respond(data)
    end
    []
  end

  # Answer first (Discord allows 3 s), then review, then edit the message
  # once (new status, buttons and a freshly rendered map image).
  def respond(interaction)
    plan = @handler.prepare(interaction)
    return unless plan

    @client.interaction_callback(interaction['id'], interaction['token'], plan.response)
    answered = true
    return unless plan.work

    outcome = plan.work.call || {}
    followup(interaction, outcome[:error]) if outcome[:error]
    @refresher.call(outcome[:segment_id]) if outcome[:segment_id]
  rescue StandardError => e
    @logger.error("[GTFS discord] interaction #{interaction['id']} failed: #{e.class}: #{e.message}")
    followup(interaction, safe_text('try_again')) if answered
  end

  # The text in the configured language, or in the default one when the
  # setting cannot be read (the error being handled may be the database's).
  def safe_text(key)
    Gtfs::Discord::Texts.t(key)
  rescue StandardError
    Gtfs::Discord::Texts.t(key, Gtfs::Discord::Texts::DEFAULT)
  end

  def followup(interaction, text)
    @client.followup(interaction['application_id'], interaction['token'],
                     { content: text, flags: Gtfs::Discord::InteractionHandler::EPHEMERAL })
  rescue StandardError => e
    @logger.error("[GTFS discord] follow-up for interaction #{interaction['id']} failed: #{e.class}")
  end

  def refresh_in_background(segment_id)
    Thread.new do
      Rails.application.executor.wrap { Gtfs::Discord::SyncMessageJob.perform_now(segment_id) }
    rescue StandardError => e
      @logger.error("[GTFS discord] map refresh of segment #{segment_id} failed: #{e.class}: #{e.message}")
    end
  end

  # --- websocket plumbing (needs the network; #run is specced with this stubbed) ---

  def connect_and_listen
    @heartbeat_interval = nil # set again by this connection's HELLO
    base = (resumable? && @resume_url.presence) || @client.gateway_url
    url = "#{base}/?v=10&encoding=json"
    uri = URI(url)
    tcp = TCPSocket.new(uri.host, uri.port || 443)
    ssl = OpenSSL::SSL::SSLSocket.new(tcp, OpenSSL::SSL::SSLContext.new.tap do |c|
      c.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
    end)
    ssl.hostname = uri.host
    ssl.sync_close = true
    ssl.connect
    @socket = ssl
    driver = WebSocket::Driver.client(SocketAdapter.new(url, ssl, @write_lock))
    closed = nil
    driver.on(:message) { |event| send_all(driver, handle(JSON.parse(event.data))) }
    driver.on(:close) { |event| closed = [event.code, event.reason] }
    driver.start
    heartbeat_thread = start_heartbeats(driver)
    loop do
      closed!(*closed) if closed
      raise Reconnect, 'stopped' if @stopped

      driver.parse(ssl.readpartial(65_536))
    end
  rescue IOError, Errno::ECONNRESET => e # EOFError is an IOError
    closed!(*closed) if closed # Discord sent a close frame, then hung up: its code decides
    raise Reconnect, e.class.name
  ensure
    heartbeat_thread&.kill
    @socket&.close
  end

  def start_heartbeats(driver)
    Thread.new do
      sleep 0.1 until @heartbeat_interval
      sleep(@heartbeat_interval * rand) # first beat with jitter, as documented
      loop do
        unless heartbeat_due!
          @socket&.close # zombie connection: the read loop raises and reconnects
          break
        end
        write(driver, heartbeat)
        sleep @heartbeat_interval
      end
    end
  end

  def send_all(driver, payloads)
    payloads.each { |payload| write(driver, payload) }
  end

  # The driver frames the text and writes it to the socket; one writer at a
  # time (heartbeat thread vs. read loop).
  def write(driver, payload)
    @write_lock.synchronize { driver.text(JSON.generate(payload)) }
  end

  # The driver also writes on its own (pong, close): same lock, re-entrant
  # for the calls made from #write.
  SocketAdapter = Struct.new(:url, :socket, :lock) do
    def write(data)
      lock.owned? ? socket.write(data) : lock.synchronize { socket.write(data) }
    end
  end
end
