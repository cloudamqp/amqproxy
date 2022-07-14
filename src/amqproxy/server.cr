require "socket"
require "openssl"
require "logger"
require "amq-protocol"
require "./pool"
require "./client"
require "./upstream"

module AMQProxy
  class Server
    @running = true
    @draining = false

    def initialize(upstream_host, upstream_port, upstream_tls, log_level = Logger::INFO, idle_connection_timeout = 5, graceful_shutdown = false, graceful_shutdown_timeout = 0)
      @log = Logger.new(STDOUT)
      @log.level = log_level
      journald =
        {% if flag?(:unix) %}
          if journal_stream = ENV.fetch("JOURNAL_STREAM", nil)
            stdout_stat = STDOUT.info.@stat
            journal_stream == "#{stdout_stat.st_dev}:#{stdout_stat.st_ino}"
          end
        {% else %}
          false
        {% end %}
      @log.formatter = Logger::Formatter.new do |_severity, datetime, _progname, message, io|
        io << datetime << ": " unless journald
        io << message
      end
      @clients = Array(Client).new
      @pool = Pool.new(upstream_host, upstream_port, upstream_tls, @log, idle_connection_timeout)
      @graceful_shutdown = graceful_shutdown
      @graceful_shutdown_timeout = graceful_shutdown_timeout
      @log.info "Proxy upstream: #{upstream_host}:#{upstream_port} #{upstream_tls ? "TLS" : ""}"
    end

    def client_connections
      @clients.size
    end

    def upstream_connections
      @pool.size
    end

    def running
      @running
    end

    def listen(address, port)
      @socket = socket = TCPServer.new(address, port)
      @log.info "Proxy listening on #{socket.local_address}"
      while @running
        if client = socket.accept?
          if @draining
            @log.debug "Rejecting new connection #{client.remote_address}"
            client.close
            next
          end
          addr = client.remote_address
          spawn handle_connection(client, addr), name: "handle connection #{addr}"
        else
          break
        end
      end
    end

    def listen_tls(address, port, cert_path : String, key_path : String)
      @socket = socket = TCPServer.new(address, port)
      context = OpenSSL::SSL::Context::Server.new
      context.private_key = key_path
      context.certificate_chain = cert_path
      @log.info "Proxy listening on #{socket.local_address}:#{port} (TLS)"
      while @running
        if client = socket.accept?
          if @draining
            @log.debug "Rejecting new connection #{client.remote_address}"
            client.close
            next
          end
          begin
            addr = client.remote_address
            ssl_client = OpenSSL::SSL::Socket::Server.new(client, context)
            ssl_client.sync_close = true
            spawn handle_connection(ssl_client, addr), name: "handle connection #{addr} (tls)"
          rescue e : OpenSSL::SSL::Error
            @log.error "Error accepting OpenSSL connection from #{client.remote_address}: #{e.inspect}"
          end
        else
          break
        end
      end
    end

    def wait_for_drain
      @draining = true
      @log.info "Waiting for open connections to be closed by remote"
      last_client_debug_log = 0
      drain_started = Time.utc.to_unix
      while @clients.size > 0
        current_time = Time.utc.to_unix
        if (last_client_debug_log < current_time - 15)
          last_client_debug_log = current_time
          @log.info "#{@clients.size} client(s) remaining"
          @clients.each do |client|
            @log.debug "- Client #{client.socket.as(TCPSocket).remote_address} since #{(client.lifetime.total_minutes.floor.to_i)}m #{client.lifetime.seconds}s"
          end
        end
        if @graceful_shutdown_timeout > 0 && Time.utc.to_unix - drain_started > @graceful_shutdown_timeout
          @log.info "Forcing shutdown after #{@graceful_shutdown_timeout} seconds"
          break
        end
        sleep 500.milliseconds
      end
      @log.info "All connections closed. Stopping server"
    end

    def close(force = false)
      if force
        @log.info "Forcing shutdown after signal"
      else
        @log.info "Proxy stopping accepting connections"
      end
      wait_for_drain if @graceful_shutdown && !force
      @running = false
      @socket.try &.close
      @clients.each &.close
      @pool.try &.close
    end

    private def handle_connection(socket, remote_address)
      socket.sync = false
      socket.keepalive = true
      socket.tcp_nodelay = true
      socket.tcp_keepalive_idle = 60
      socket.tcp_keepalive_count = 3
      socket.tcp_keepalive_interval = 10
      @log.debug { "Client connected: #{remote_address}" }
      vhost, user, password = Client.negotiate(socket)
      c = Client.new(socket)
      active_client(c) do
        @pool.borrow(user, password, vhost) do |u|
          # print "\r#{@clients.size} clients\t\t #{@pool.size} upstreams"
          u.current_client = c
          c.read_loop(u)
        ensure
          u.current_client = nil
          u.client_disconnected
        end
      rescue ex : Upstream::AccessError
        @log.error { "Access refused for user '#{user}' to vhost '#{vhost}', reason: #{ex.message}" }
        close = AMQ::Protocol::Frame::Connection::Close.new(403_u16, "ACCESS_REFUSED - #{ex.message}", 0_u16, 0_u16)
        close.to_io socket, IO::ByteFormat::NetworkEndian
        socket.flush
      rescue ex : Upstream::Error
        @log.error { "Upstream error for user '#{user}' to vhost '#{vhost}': #{ex.inspect} (cause: #{ex.cause.inspect})" }
        close = AMQ::Protocol::Frame::Connection::Close.new(403_u16, "UPSTREAM_ERROR", 0_u16, 0_u16)
        close.to_io socket, IO::ByteFormat::NetworkEndian
        socket.flush
      end
    rescue ex : Client::Error
      @log.debug { "Client disconnected: #{remote_address}: #{ex.inspect}" }
    ensure
      @log.debug { "Client disconnected: #{remote_address}" }
      socket.close rescue nil
      # print "\r#{@clients.size} clients\t\t #{@pool.size} upstreams"
    end

    private def active_client(client)
      @clients << client
      yield client
    ensure
      @clients.delete client
    end
  end
end
