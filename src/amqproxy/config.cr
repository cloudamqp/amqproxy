require "ini"
require "log"
require "option_parser"

module AMQProxy
  struct Config
    getter listen_address : String = "localhost"
    getter listen_port : Int32 = 5673
    getter http_port : Int32 = 15673
    getter log_level : Log::Severity = Log::Severity::Info
    getter idle_connection_timeout : Int32 = 5
    getter term_timeout : Int32 = -1
    getter term_client_close_timeout : Int32 = 0
    getter upstream : String?

    protected def load_from_file(path : String?) # ameba:disable Metrics/CyclomaticComplexity
      if path.nil? || path.empty? || !File.exists?(path)
        return self
      end

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
    rescue ex
      abort ex.message
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

    protected def load_from_options(options) # ameba:disable Metrics/CyclomaticComplexity
      @listen_address = options.listen_address || @listen_address
      @listen_port = options.listen_port || @listen_port
      @http_port = options.http_port || @http_port
      @idle_connection_timeout = options.idle_connection_timeout || @idle_connection_timeout
      @term_timeout = options.term_timeout || @term_timeout
      @term_client_close_timeout = options.term_client_close_timeout || @term_client_close_timeout
      @log_level = options.log_level || @log_level
      @upstream = options.upstream || @upstream

      # the debug flag overrules the log level. Only set the level
      # when it is not already set to debug or trace
      if options.debug? && log_level > Log::Severity::Debug
        @log_level = Log::Severity::Debug
      end

      self
    end

    def self.load_with_cli(options : Options)
      new()
        .load_from_file(options.ini_file || "config.ini")
        .load_from_env
        .load_from_options(options)
    end
  end
end
