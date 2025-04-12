require "ini"
require "log"
require "option_parser"

module AMQProxy
  class Config
    getter listen_address = "localhost"
    getter listen_port = 5673
    getter http_port = 15673
    getter log_level = Log::Severity::Info
    getter idle_connection_timeout = 5
    getter term_timeout = -1
    getter term_client_close_timeout = 0
    getter upstream : String? = nil
    getter debug = false
    getter config_file = "config.ini"

    protected def load_from_file # ameba:disable Metrics/CyclomaticComplexity
      if config_file.empty? || !File.exists?(config_file)
        return self
      end

      INI.parse(File.read(config_file)).each do |name, section|
        case name
        when "main", ""
          section.each do |key, value|
            case key
            when "upstream"                  then @upstream = value
            when "log_level"                 then @log_level = ::Log::Severity.parse(value)
            when "idle_connection_timeout"   then @idle_connection_timeout = value.to_i
            when "term_timeout"              then @term_timeout = value.to_i
            when "term_client_close_timeout" then @term_client_close_timeout = value.to_i
            else                                  raise "Unsupported config #{name}/#{key}"
            end
          end
        when "listen"
          section.each do |key, value|
            case key
            when "http_port"       then @http_port = value.to_i
            when "port"            then @listen_port = value.to_i
            when "bind", "address" then @listen_address = value
            when "log_level"       then @log_level = ::Log::Severity.parse(value)
            else                        raise "Unsupported config #{name}/#{key}"
            end
          end
        else raise "Unsupported config section #{name}"
        end
      end

      self
    end

    protected def load_from_env # ameba:disable Metrics/CyclomaticComplexity
      @listen_address = ENV["LISTEN_ADDRESS"]? || @listen_address
      @listen_port = ENV["LISTEN_PORT"]?.try &.to_i || @listen_port
      @http_port = ENV["HTTP_PORT"]?.try &.to_i || @http_port
      @log_level = Log::Severity.parse(ENV["LOG_LEVEL"]? || self.log_level.to_s) || @log_level
      @idle_connection_timeout = ENV["IDLE_CONNECTION_TIMEOUT"]?.try &.to_i || @idle_connection_timeout
      @term_timeout = ENV["TERM_TIMEOUT"]?.try &.to_i || @term_timeout
      @term_client_close_timeout = ENV["TERM_CLIENT_CLOSE_TIMEOUT"]?.try &.to_i || @term_client_close_timeout
      @upstream = ENV["AMQP_URL"]? || ENV["UPSTREAM"]? || @upstream

      self
    end

    protected def load_cli_options(argv)
      OptionParser.parse(argv) do |parser|
        parser.on("-l ADDRESS", "--listen=ADDRESS", "Address to listen on (default is localhost)") do |v|
          @listen_address = v
        end
        parser.on("-p PORT", "--port=PORT", "Port to listen on (default: 5673)") { |v| @listen_port = v.to_i }
        parser.on("-b PORT", "--http-port=PORT", "HTTP Port to listen on (default: 15673)") { |v| @http_port = v.to_i }
        parser.on("-t IDLE_CONNECTION_TIMEOUT", "--idle-connection-timeout=SECONDS", "Maximum time in seconds an unused pooled connection stays open (default 5s)") do |v|
          @idle_connection_timeout = v.to_i
        end
        parser.on("--term-timeout=SECONDS", "At TERM the server waits SECONDS seconds for clients to gracefully close their sockets after Close has been sent (default: infinite)") do |v|
          @term_timeout = v.to_i
        end
        parser.on("--term-client-close-timeout=SECONDS", "At TERM the server waits SECONDS seconds for clients to send Close beforing sending Close to clients (default: 0s)") do |v|
          @term_client_close_timeout = v.to_i
        end
        parser.on("--log-level=LEVEL", "The log level (default: info)") { |v| @log_level = ::Log::Severity.parse(v) }
        parser.on("-d", "--debug", "Verbose logging") { @debug = true }
        parser.on("-c FILE", "--config=FILE", "Load config file") do |v|
          @config_file = v
        end
        parser.on("-h", "--help", "Show this help") { puts parser.to_s; exit 0 }
        parser.on("-v", "--version", "Display version") { puts AMQProxy::VERSION.to_s; exit 0 }
        parser.invalid_option { |arg| abort "Invalid argument: #{arg}" }
      end

      @upstream = argv.shift? || @upstream

      if @debug && @log_level > Log::Severity::Debug
        @log_level = Log::Severity::Debug
      end

      self
    end
  
    def self.load_with_cli(argv)
      new()
        .load_cli_options(argv.dup) # handle config file/help/version options
        .load_from_file
        .load_from_env
        .load_cli_options(argv)
      rescue ex
        abort ex.message
    end
  end
end
