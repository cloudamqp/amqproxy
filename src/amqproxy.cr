require "./amqproxy/version"
require "./amqproxy/server"
require "option_parser"
require "uri"
require "ini"
require "logger"

class AMQProxy::CLI
  @listen_address = ENV["LISTEN_ADDRESS"]? || "localhost"
  @listen_port = ENV["LISTEN_PORT"]? || 5673
  @log_level : Logger::Severity = Logger::INFO
  @graceful_shutdown = false
  @idle_connection_timeout = 5
  @upstream = ENV["AMQP_URL"]?

  def parse_config(path)
    INI.parse(File.read(path)).each do |name, section|
      case name
      when "main", ""
        section.each do |key, value|
          case key
          when "upstream"                then @upstream = value
          when "log_level"               then @log_level = Logger::Severity.parse(value)
          when "graceful_shutdown"       then @graceful_shutdown = (value == "true")
          when "idle_connection_timeout" then @idle_connection_timeout = value.to_i
          else                                raise "Unsupported config #{name}/#{key}"
          end
        end
      when "listen"
        section.each do |key, value|
          case key
          when "port"            then @listen_port = value
          when "bind", "address" then @listen_address = value
          when "log_level"       then @log_level = Logger::Severity.parse(value)
          else                        raise "Unsupported config #{name}/#{key}"
          end
        end
      else raise "Unsupported config section #{name}"
      end
    end
  rescue ex
    abort ex.message
  end

  def run
    p = OptionParser.parse do |parser|
      parser.banner = "Usage: amqproxy [options] [amqp upstream url]"
      parser.on("-l ADDRESS", "--listen=ADDRESS", "Address to listen on (default is localhost)") do |v|
        @listen_address = v
      end
      parser.on("-p PORT", "--port=PORT", "Port to listen on (default: 5673)") { |v| @listen_port = v.to_i }
      parser.on("-t IDLE_CONNECTION_TIMEOUT", "--idle-connection-timeout=SECONDS", "Maxiumum time in seconds an unused pooled connection stays open (default 5s)") do |v|
        @idle_connection_timeout = v.to_i
      end
      parser.on("-d", "--debug", "Verbose logging") { @log_level = Logger::DEBUG }
      parser.on("-g", "--graceful_shutdown", "Reject new connections and wait for established conenctions to be closed before shutting down") { @graceful_shutdown = true }
      parser.on("-c FILE", "--config=FILE", "Load config file") { |v| parse_config(v) }
      parser.on("-h", "--help", "Show this help") { puts parser.to_s; exit 0 }
      parser.on("-v", "--version", "Display version") { puts AMQProxy::VERSION.to_s; exit 0 }
      parser.invalid_option { |arg| abort "Invalid argument: #{arg}" }
    end

    @upstream ||= ARGV.shift?
    abort p.to_s if @upstream.nil?

    u = URI.parse @upstream.not_nil!
    abort "Invalid upstream URL" unless u.host
    default_port =
      case u.scheme
      when "amqp"  then 5672
      when "amqps" then 5671
      else              abort "Not a valid upstream AMQP URL, should be on the format of amqps://hostname"
      end
    port = u.port || default_port
    tls = u.scheme == "amqps"

    server = AMQProxy::Server.new(u.host || "", port, tls, @log_level, @idle_connection_timeout, @graceful_shutdown)

    @got_sigterm = false
    shutdown = ->(_s : Signal) do
      if @got_sigterm
        return
      end
      @got_sigterm = true
      server.close
      exit 0
    end
    Signal::INT.trap &shutdown
    Signal::TERM.trap &shutdown

    server.listen(@listen_address, @listen_port.to_i)
  end
end

AMQProxy::CLI.new.run
