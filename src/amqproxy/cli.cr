require "./version"
require "./server"
require "./http_server"
require "option_parser"
require "uri"
require "ini"
require "log"

class AMQProxy::CLI
  Log = ::Log.for(self)

  @listen_address = ENV["LISTEN_ADDRESS"]? || "localhost"
  @listen_port = ENV["LISTEN_PORT"]? || 5673
  @http_port = ENV["HTTP_PORT"]? || 15673
  @log_level : ::Log::Severity = ::Log::Severity::Info
  @idle_connection_timeout : Int32 = ENV.fetch("IDLE_CONNECTION_TIMEOUT", "5").to_i
  @ssl_verify_mode = ENV["SSL_VERIFY_MODE"]? || OpenSSL::SSL::VerifyMode::PEER.to_s
  @term_timeout = -1
  @term_client_close_timeout = 0
  @upstream = ENV["AMQP_URL"]?
  @server : AMQProxy::Server? = nil

  def parse_config(path) # ameba:disable Metrics/CyclomaticComplexity
    INI.parse(File.read(path)).each do |name, section|
      case name
      when "main", ""
        section.each do |key, value|
          case key
          when "upstream"                  then @upstream = value
          when "log_level"                 then @log_level = ::Log::Severity.parse(value)
          when "idle_connection_timeout"   then @idle_connection_timeout = value.to_i
          when "term_timeout"              then @term_timeout = value.to_i
          when "term_client_close_timeout" then @term_client_close_timeout = value.to_i
          when "ssl_verify_mode"           then @ssl_verify_mode = value
          else                                  raise "Unsupported config #{name}/#{key}"
          end
        end
      when "listen"
        section.each do |key, value|
          case key
          when "port"            then @listen_port = value
          when "bind", "address" then @listen_address = value
          when "log_level"       then @log_level = ::Log::Severity.parse(value)
          else                        raise "Unsupported config #{name}/#{key}"
          end
        end
      else raise "Unsupported config section #{name}"
      end
    end
  rescue ex
    abort ex.message
  end

  def run(argv)
    raise "run cant be called multiple times" unless @server.nil?

    p = OptionParser.parse(argv) do |parser|
      parser.banner = "Usage: amqproxy [options] [amqp upstream url]"
      parser.on("-l ADDRESS", "--listen=ADDRESS", "Address to listen on (default is localhost)") do |v|
        @listen_address = v
      end
      parser.on("-p PORT", "--port=PORT", "Port to listen on (default: 5673)") { |v| @listen_port = v.to_i }
      parser.on("-b PORT", "--http-port=PORT", "HTTP Port to listen on (default: 15673)") { |v| @http_port = v.to_i }
      parser.on("-t IDLE_CONNECTION_TIMEOUT", "--idle-connection-timeout=SECONDS", "Maxiumum time in seconds an unused pooled connection stays open (default 5s)") do |v|
        @idle_connection_timeout = v.to_i
      end
      parser.on("-s SSL_VERIFY_MODE", "--ssl-verify-mode=VALUE", "SSL Verification Mode (default PEER). See OpenSSL::SSL::VerifyMode.") do |v|
        @ssl_verify_mode = v
      end
      parser.on("--term-timeout=SECONDS", "At TERM the server waits SECONDS seconds for clients to gracefully close their sockets after Close has been sent (default: infinite)") do |v|
        @term_timeout = v.to_i
      end
      parser.on("--term-client-close-timeout=SECONDS", "At TERM the server waits SECONDS seconds for clients to send Close beforing sending Close to clients (default: 0s)") do |v|
        @term_client_close_timeout = v.to_i
      end
      parser.on("-d", "--debug", "Verbose logging") { @log_level = ::Log::Severity::Debug }
      parser.on("-c FILE", "--config=FILE", "Load config file") { |v| parse_config(v) }
      parser.on("-h", "--help", "Show this help") { puts parser.to_s; exit 0 }
      parser.on("-v", "--version", "Display version") { puts AMQProxy::VERSION.to_s; exit 0 }
      parser.invalid_option { |arg| abort "Invalid argument: #{arg}" }
    end

    @upstream ||= argv.shift?
    upstream_url = @upstream || abort p.to_s

    u = URI.parse upstream_url
    abort "Invalid upstream URL" unless u.host
    default_port =
      case u.scheme
      when "amqp"  then 5672
      when "amqps" then 5671
      else              abort "Not a valid upstream AMQP URL, should be on the format of amqps://hostname"
      end
    port = u.port || default_port
    tls = u.scheme == "amqps"

    log_backend = if ENV.has_key?("JOURNAL_STREAM")
                    ::Log::IOBackend.new(formatter: Journal::LogFormat, dispatcher: ::Log::DirectDispatcher)
                  else
                    ::Log::IOBackend.new(formatter: Stdout::LogFormat, dispatcher: ::Log::DirectDispatcher)
                  end
    ::Log.setup_from_env(default_level: @log_level, backend: log_backend)

    Signal::INT.trap &->self.initiate_shutdown(Signal)
    Signal::TERM.trap &->self.initiate_shutdown(Signal)

    ssl_verify_mode = OpenSSL::SSL::VerifyMode.parse?(@ssl_verify_mode) || abort("Invalid SSL verify mode #{@ssl_verify_mode}")
    server = @server = AMQProxy::Server.new(u.hostname || "", port, tls, @idle_connection_timeout, ssl_verify_mode)

    HTTPServer.new(server, @listen_address, @http_port.to_i)
    server.listen(@listen_address, @listen_port.to_i)

    shutdown

    # wait until all client connections are closed
    until server.client_connections.zero?
      sleep 0.2
    end
    Log.info { "No clients left. Exiting." }
  end

  @first_shutdown = true

  def initiate_shutdown(_s : Signal)
    unless server = @server
      exit 0
    end
    if @first_shutdown
      @first_shutdown = false
      server.stop_accepting_clients
    else
      abort "Exiting with #{server.client_connections} client connections still open"
    end
  end

  def shutdown
    unless server = @server
      raise "Can't call shutdown before run"
    end
    if server.client_connections > 0
      if @term_client_close_timeout > 0
        wait_for_clients_to_close @term_client_close_timeout.seconds
      end
      server.disconnect_clients
    end

    if server.client_connections > 0
      if @term_timeout >= 0
        spawn do
          sleep @term_timeout
          abort "Exiting with #{server.client_connections} client connections still open"
        end
      end
    end
  end

  def wait_for_clients_to_close(close_timeout)
    unless server = @server
      raise "Can't call shutdown before run"
    end
    Log.info { "Waiting for clients to close their connections." }
    ch = Channel(Bool).new
    spawn do
      loop do
        ch.send true if server.client_connections.zero?
        sleep 0.1.seconds
      end
    rescue Channel::ClosedError
    end

    select
    when ch.receive?
      Log.info { "All clients has closed their connections." }
    when timeout close_timeout
      ch.close
      Log.info { "Timeout waiting for clients to close their connections." }
    end
  end

  struct Journal::LogFormat < ::Log::StaticFormatter
    def run
      source
      context(before: '[', after: ']')
      string ' '
      message
      exception
    end
  end

  struct Stdout::LogFormat < ::Log::StaticFormatter
    def run
      timestamp
      severity
      source(before: ' ')
      context(before: '[', after: ']')
      string ' '
      message
      exception
    end
  end
end
