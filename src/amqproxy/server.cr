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

    def initialize(upstream_host, upstream_port, upstream_tls, log_level = Logger::INFO)
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
      @log.formatter = Logger::Formatter.new do |severity, datetime, progname, message, io|
        io << datetime << ": " unless journald
        io << message
      end
      @clients = Array(Client).new
      @pool = Pool.new(upstream_host, upstream_port, upstream_tls, @log)
      @log.info "Proxy upstream: #{upstream_host}:#{upstream_port} #{upstream_tls ? "TLS" : ""}"
    end

    def client_connections
      @clients.size
    end

    def upstream_connections
      @pool.size
    end

    def listen(address, port)
      @socket = socket = TCPServer.new(address, port)
      @log.info "Proxy listening on #{socket.local_address}"
      while @running
        if client = socket.accept?
          addr = client.remote_address
          spawn handle_connection(client, addr), name: "handle connection #{addr}"
        else
          break
        end
      end
      @log.info "Proxy stopping accepting connections"
    end

    def listen_tls(address, port, cert_path : String, key_path : String)
      @socket = socket = TCPServer.new(address, port)
      context = OpenSSL::SSL::Context::Server.new
      context.private_key = key_path
      context.certificate_chain = cert_path
      @log.info "Proxy listening on #{socket.local_address}:#{port} (TLS)"
      while @running
        if client = socket.accept?
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
      @log.info "Proxy stopping accepting connections"
    end

    def close
      @running = false
      @socket.try &.close
      @pool.try &.close
      @clients.each &.close
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
        @log.error { "Upstream error for user '#{user}' to vhost '#{vhost}': #{ex.inspect}" }
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
