require "./config"
require "./version"
require "./server"
require "./http_server"
require "option_parser"
require "uri"
require "ini"
require "log"

class AMQProxy::CLI
  Log = ::Log.for(self)

  @config : Config
  @server : AMQProxy::Server? = nil

  def run(argv)
    raise "run cant be called multiple times" unless @server.nil?

    file : String? = nil

    # validate options and get config file when specified
    p = OptionParser.parse(argv) do |parser|
      parser.banner = "Usage: amqproxy [options] [amqp upstream url]"
      parser.on("-l ADDRESS", "--listen=ADDRESS", "Address to listen on (default is localhost)") { }
      parser.on("-p PORT", "--port=PORT", "Port to listen on (default: 5673)") { }
      parser.on("-b PORT", "--http-port=PORT", "HTTP Port to listen on (default: 15673)") { }
      parser.on("-t IDLE_CONNECTION_TIMEOUT", "--idle-connection-timeout=SECONDS", "Maxiumum time in seconds an unused pooled connection stays open (default 5s)") { }
      parser.on("--term-timeout=SECONDS", "At TERM the server waits SECONDS seconds for clients to gracefully close their sockets after Close has been sent (default: infinite)") { }
      parser.on("--term-client-close-timeout=SECONDS", "At TERM the server waits SECONDS seconds for clients to send Close beforing sending Close to clients (default: 0s)") { }
      parser.on("--log-level=LEVEL", "The log level (default: info)") { }
      parser.on("-d", "--debug", "Verbose logging") { }
      parser.on("-c FILE", "--config=FILE", "Load config file") { |v| file = v }
      parser.on("-h", "--help", "Show this help") { puts parser.to_s; exit 0 }
      parser.on("-v", "--version", "Display version") { puts AMQProxy::VERSION.to_s; exit 0 }
      parser.invalid_option { |arg| abort "Invalid argument: #{arg}" }
    end

    @config = AMQProxy::Config.load_with_cli(argv, file)

    u = URI.parse @config.upstream
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
    ::Log.setup_from_env(default_level: @config.log_level, backend: log_backend)

    Signal::INT.trap &->self.initiate_shutdown(Signal)
    Signal::TERM.trap &->self.initiate_shutdown(Signal)

    server = @server = AMQProxy::Server.new(u.hostname || "", port, tls, @config.idle_connection_timeout)

    HTTPServer.new(server, @config.listen_address, @config.http_port)
    server.listen(config.listen_address, @config.listen_port)

    shutdown

    # wait until all client connections are closed
    until server.client_connections.zero?
      sleep 0.2.seconds
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
      if @config.term_client_close_timeout > 0
        wait_for_clients_to_close @config.term_client_close_timeout.seconds
      end
      server.disconnect_clients
    end

    if server.client_connections > 0
      if @config.term_timeout >= 0
        spawn do
          sleep @config.term_timeout
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
