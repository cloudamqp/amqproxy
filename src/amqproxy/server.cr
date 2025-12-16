require "socket"
require "log"
require "amq-protocol"
require "uri"
require "./channel_pool"
require "./client"
require "./upstream"
require "./connection_info"

module AMQProxy
  class Server
    Log = ::Log.for(self)
    @clients_lock = Mutex.new
    @clients = Array(Client).new
    @closed = false

    def self.new(url : URI)
      tls = url.scheme == "amqps"
      host = url.host || "127.0.0.1"
      port = url.port || 5762
      port = 5671 if tls && url.port.nil?
      idle_connection_timeout = url.query_params.fetch("idle_connection_timeout", 5).to_i
      new(host, port, tls, idle_connection_timeout)
    end

    def initialize(upstream_host, upstream_port, upstream_tls, idle_connection_timeout = 5)
      tls_ctx = OpenSSL::SSL::Context::Client.new if upstream_tls
      @channel_pools = Hash(Credentials, ChannelPool).new do |hash, credentials|
        hash[credentials] = ChannelPool.new(upstream_host, upstream_port, tls_ctx, credentials, idle_connection_timeout)
      end
      Log.info { "Proxy upstream: #{upstream_host}:#{upstream_port} #{upstream_tls ? "TLS" : ""}" }
    end

    def client_connections
      @clients.size
    end

    def upstream_connections
      @channel_pools.each_value.sum &.connections
    end

    def listen(address, port)
      listen(TCPServer.new(address, port))
    end

    def listen(@server : TCPServer)
      Log.info { "Proxy listening on #{server.local_address}" }
      loop do
        socket = server.accept? || break
        begin
          remote_addr = socket.remote_address
          set_socket_options(socket)
          conn_info = ConnectionInfo.new(remote_addr, socket.local_address)
          spawn handle_connection(socket, conn_info), name: "Client#read_loop #{remote_addr}"
        rescue IO::Error
          next
        end
      end
      Log.info { "Proxy stopping accepting connections" }
    end

    def listen_tls(address, port, context)
      listen_tls(TCPServer.new(address, port), context)
    end

    def listen_tls(s : TCPServer, context)
      # @listeners[s] = protocol
      Log.info { "Listening on #{s.local_address} (TLS)" }
      loop do # do not try to use while
        client = s.accept? || break
        next client.close if @closed
        accept_tls(client, context)
      end
    rescue ex : IO::Error | OpenSSL::Error
      abort "Unrecoverable error in TLS listener: #{ex.inspect_with_backtrace}"
      # ensure
      #  @listeners.delete(s)
    end

    private def accept_tls(client, context)
      if context
        spawn(name: "Accept TLS socket") do
          remote_addr = client.remote_address
          set_socket_options(client)
          ssl_client = OpenSSL::SSL::Socket::Server.new(client, context, sync_close: true)
          # ssl_client = OpenSSL::SSL::Socket.new(client, context, sync_close: true)
          set_buffer_size(ssl_client)
          Log.debug { "#{remote_addr} connected with #{ssl_client.tls_version} #{ssl_client.cipher}" }
          conn_info = ConnectionInfo.new(remote_addr, client.local_address)
          conn_info.ssl = true
          conn_info.ssl_version = ssl_client.tls_version
          conn_info.ssl_cipher = ssl_client.cipher
          handle_connection(ssl_client, conn_info)
        rescue ex
          Log.warn(exception: ex) { "Error accepting TLS connection from #{remote_addr}" }
          client.close rescue nil
        end
      end
    end

    def listen_tls(bind, port, context)
      listen_tls(TCPServer.new(bind, port), context)
    end

    private def set_buffer_size(socket)
      socket.sync = true
      socket.read_buffering = false
    end

    def stop_accepting_clients
      @server.try &.close
    end

    def disconnect_clients
      Log.info { "Disconnecting clients" }
      @clients_lock.synchronize do
        @clients.each &.close # send Connection#Close frames
      end
    end

    def close_sockets
      Log.info { "Closing client sockets" }
      @clients_lock.synchronize do
        @clients.each &.close_socket # close sockets forcefully
      end
    end

    private def handle_connection(socket, connection_info)
      c = Client.new(socket, connection_info)
      active_client(c) do
        channel_pool = @channel_pools[c.credentials]
        c.read_loop(channel_pool)
      end
    rescue IO::EOFError
      # Client closed connection before/while negotiating
    rescue ex # only raise from constructor, when negotating
      Log.debug(exception: ex) { "Client negotiation failure (#{connection_info.remote_address}) #{ex.inspect}" }
    ensure
      socket.close rescue nil
    end

    private def set_socket_options(socket)
      # Note:  Very minimal support for socket options for now
      unless socket.remote_address.loopback?
        # if keepalive = @config.tcp_keepalive
        socket.keepalive = true
        socket.tcp_keepalive_idle = 60
        socket.tcp_keepalive_interval = 10
        socket.tcp_keepalive_count = 3
        # end
      end
      socket.tcp_nodelay = true # if @config.tcp_nodelay?
      # @config.tcp_recv_buffer_size.try { |v| socket.recv_buffer_size = v }
      # @config.tcp_send_buffer_size.try { |v| socket.send_buffer_size = v }
    end

    private def active_client(client, &)
      @clients_lock.synchronize do
        @clients << client
      end
      yield client
    ensure
      @clients_lock.synchronize do
        @clients.delete client
      end
    end
  end
end
