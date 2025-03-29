require "ini"
require "log"
require "option_parser"

module AMQProxy
  record Config,
    listen_address : String,
    listen_port : Int32,
    http_port : Int32,
    log_level : Log::Severity,
    idle_connection_timeout : Int32,
    term_timeout : Int32,
    term_client_close_timeout : Int32,
    upstream : String? do

    # Factory method to create a Config with nullable parameters
    private def self.create(
      listen_address : String? = nil, 
      listen_port : Int32? = nil,
      http_port : Int32? = nil,
      log_level : Log::Severity? = nil,
      idle_connection_timeout : Int32? = nil,
      term_timeout : Int32? = nil,
      term_client_close_timeout : Int32? = nil,
      upstream : String? = nil
    )
      new(
        listen_address || "localhost",
        listen_port || 5673,
        http_port || 15673,
        log_level || Log::Severity::Info,
        idle_connection_timeout || 5,
        term_timeout || -1,
        term_client_close_timeout || 0,
        upstream || nil
      )
    end

    # Method to return a new instance with modified fields (like C# `with`)
    protected def with(
      listen_address : String? = nil, 
      listen_port : Int32? = nil,
      http_port : Int32? = nil,
      log_level : Log::Severity? = nil,
      idle_connection_timeout : Int32? = nil,
      term_timeout : Int32? = nil,
      term_client_close_timeout : Int32? = nil,
      upstream : String? = nil
    )
      Config.new(
        listen_address || self.listen_address,
        listen_port || self.listen_port,
        http_port || self.http_port,
        log_level || self.log_level,
        idle_connection_timeout || self.idle_connection_timeout,
        term_timeout || self.term_timeout,
        term_client_close_timeout || self.term_client_close_timeout,
        upstream || self.upstream
      )
    end

    protected def load_from_file(path : String) # ameba:disable Metrics/CyclomaticComplexity
      return self unless File.exists?(path)

      config = self

      INI.parse(File.read(path)).each do |name, section|
        case name
        when "main", ""
          section.each do |key, value|
            case key
            when "upstream"                  then config = config.with(upstream: value)
            when "log_level"                 then config = config.with(log_level: ::Log::Severity.parse(value))
            when "idle_connection_timeout"   then config = config.with(idle_connection_timeout: value.to_i)
            when "term_timeout"              then config = config.with(term_timeout: value.to_i)
            when "term_client_close_timeout" then config = config.with(term_client_close_timeout: value.to_i)
            else                                  raise "Unsupported config #{name}/#{key}"
            end
          end
        when "listen"
          section.each do |key, value|
            case key
            when "http_port"       then config = config.with(http_port: value.to_i)
            when "port"            then config = config.with(listen_port: value.to_i)
            when "bind", "address" then config = config.with(listen_address: value)
            when "log_level"       then config = config.with(log_level: ::Log::Severity.parse(value))
            else                        raise "Unsupported config #{name}/#{key}"
            end
          end
        else raise "Unsupported config section #{name}"
        end
      end

      config
    rescue ex
      abort ex.message
    end

    protected def load_from_env
      self.with(
        listen_address: ENV["LISTEN_ADDRESS"]?,
        listen_port: ENV["LISTEN_PORT"]?.try &.to_i,
        http_port: ENV["HTTP_PORT"]?.try &.to_i,
        log_level: Log::Severity.parse(ENV["LOG_LEVEL"]? || self.log_level.to_s),
        idle_connection_timeout: ENV["IDLE_CONNECTION_TIMEOUT"]?.try &.to_i,
        term_timeout: ENV["TERM_TIMEOUT"]?.try &.to_i,
        term_client_close_timeout: ENV["TERM_CLIENT_CLOSE_TIMEOUT"]?.try &.to_i,
        upstream: ENV["AMQP_URL"]? || ENV["UPSTREAM"]?
      )
    end

    protected def load_from_options(options)
      config = self

      config = config.with(listen_address: options.listen_address,
                           listen_port: options.listen_port,
                           http_port: options.http_port,
                           idle_connection_timeout: options.idle_connection_timeout,
                           term_timeout: options.term_timeout,
                           term_client_close_timeout: options.term_client_close_timeout,
                           log_level: options.log_level,
                           upstream: options.upstream)

      # the debug flag overrules the log level. Only set the level
      # when it is not already set to debug or trace
      if (options.is_debug && config.log_level > Log::Severity::Debug)
        config = config.with(log_level: Log::Severity::Debug)
      end

      config
    end

    def self.load_with_cli(options : Options)
      self.create()
        .load_from_file(options.ini_file || "config.ini")
        .load_from_env()
        .load_from_options(options)
    end
  end
end
