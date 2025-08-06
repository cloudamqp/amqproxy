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

  @config : AMQProxy::Config? = nil
  @server : AMQProxy::Server? = nil

  def run(argv)
    raise "run cant be called multiple times" unless @server.nil?

    # load cascading configuration. load sequence: defaults -> file -> env -> cli
    config = @config = AMQProxy::Config.load_with_cli(argv)

    log_backend = if ENV.has_key?("JOURNAL_STREAM")
                    ::Log::IOBackend.new(formatter: Journal::LogFormat, dispatcher: ::Log::DirectDispatcher)
                  else
                    ::Log::IOBackend.new(formatter: Stdout::LogFormat, dispatcher: ::Log::DirectDispatcher)
                  end
    ::Log.setup_from_env(default_level: config.log_level, backend: log_backend)

    Log.debug { config.inspect }

    upstream_url = config.upstream || abort "Upstream AMQP url is required. Add -h switch for help."
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

    Signal::INT.trap &->self.initiate_shutdown(Signal)
    Signal::TERM.trap &->self.initiate_shutdown(Signal)

    server = @server = AMQProxy::Server.new(u.hostname || "", port, tls, config.idle_connection_timeout)

    HTTPServer.new(server, config.listen_address, config.http_port)
    server.listen(config.listen_address, config.listen_port)

    shutdown

    # wait until all client connections are closed
    until server.client_connections.zero?
      sleep 200.milliseconds
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

    unless config = @config
      raise "Configuration has not been loaded"
    end

    if server.client_connections > 0
      if config.term_client_close_timeout > 0
        wait_for_clients_to_close config.term_client_close_timeout.seconds
      end
      server.disconnect_clients
    end

    if server.client_connections > 0
      if config.term_timeout >= 0
        spawn do
          sleep config.term_timeout.seconds
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
        sleep 100.milliseconds
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
