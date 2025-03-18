require "ini"
require "log"
require "option_parser"

module AMQProxy
  class Config
    # Define instance variables and getters
    getter listen_address : String
    getter listen_port : Int32
    getter http_port : Int32
    getter log_level : Log::Severity
    getter idle_connection_timeout : Int32
    getter term_timeout : Int32
    getter term_client_close_timeout : Int32
    getter upstream : String?
  
    private def initialize(
      listen_address = "localhost",
      listen_port = 5673,
      http_port = 15673,
      log_level = Log::Severity::Info,
      idle_connection_timeout = 5,
      term_timeout = -1,
      term_client_close_timeout = 0,
      @upstream = nil
    )
      @listen_address = listen_address
      @listen_port = listen_port
      @http_port = http_port
      @log_level = log_level
      @idle_connection_timeout = idle_connection_timeout
      @term_timeout = term_timeout
      @term_client_close_timeout = term_client_close_timeout
    end
  
    protected def load_from_file(path) # ameba:disable Metrics/CyclomaticComplexity
      return unless File.exists?(path)
      
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
            else                                  raise "Unsupported config #{name}/#{key}"
            end
          end
        when "listen"
          section.each do |key, value|
            case key
            when "port"            then @listen_port = value.to_i
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
  
    # Override config using environment variables
    protected def load_with_env
      @listen_address = ENV["LISTEN_ADDRESS"]? || @listen_address
      @listen_port = ENV["LISTEN_PORT"]?.try &.to_i || @listen_port
      @http_port = ENV["HTTP_PORT"]?.try &.to_i || @http_port
      @log_level = Log::Severity.parse(ENV["LOG_LEVEL"]? || @log_level.to_s)
      @idle_connection_timeout = ENV["IDLE_CONNECTION_TIMEOUT"]?.try &.to_i || @idle_connection_timeout
      @term_timeout = ENV["TERM_TIMEOUT"]?.try &.to_i || @term_timeout
      @term_client_close_timeout = ENV["TERM_CLIENT_CLOSE_TIMEOUT"]?.try &.to_i || @term_client_close_timeout
      @upstream = ENV["UPSTREAM"]? || @upstream
    end

    # override config using command-line arguments
    protected def load_from_options(args)
      p = OptionParser.parse(args) do |parser|
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
        parser.on("--log-level=LEVEL", "The log level (default: info)") { |v| @log_level = Log::Severity.parse(v) }
      end
    end
  
    # Override config using command-line arguments
    def self.load_with_cli(args, path = "config.ini") : Config
      config = new

      # First, load config file
      config.load_from_file(path)
  
      # Then, load environment variables
      config.load_with_env
  
      # Finally, load command-line arguments
      config.load_from_options(args)

      config
    end
  end
end
