require "socket"
require "log"
require "amq-protocol"
require "uri"
require "./channel_pool"
require "./client"
require "./upstream"

module AMQProxy
  class Server
    Log = ::Log.for(self)
    @clients_lock = Mutex.new
    @clients = Array(Client).new

    def self.new(url : URI)
      tls = url.scheme == "amqps"
      host = url.host || "127.0.0.1"
      port = url.port || 5762
      port = 5671 if tls && url.port.nil?
      idle_connection_timeout = url.query_params.fetch("idle_connection_timeout", 5).to_i
      new(host, port, tls, idle_connection_timeout)
    end

    def initialize(upstream_host, upstream_port, upstream_tls, idle_connection_timeout = 5, ssl_verify_mode = OpenSSL::SSL::VerifyMode::PEER)
      tls_ctx = if upstream_tls
        context = OpenSSL::SSL::Context::Client.new
        context.verify_mode = ssl_verify_mode
        context
      end
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
      while socket = server.accept?
        begin
          addr = socket.remote_address
          spawn handle_connection(socket, addr), name: "Client#read_loop #{addr}"
        rescue IO::Error
          next
        end
      end
      Log.info { "Proxy stopping accepting connections" }
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

    private def handle_connection(socket, remote_address)
      c = Client.new(socket)
      active_client(c) do
        channel_pool = @channel_pools[c.credentials]
        c.read_loop(channel_pool)
      end
    rescue IO::EOFError
      # Client closed connection before/while negotiating
    rescue ex # only raise from constructor, when negotating
      Log.debug(exception: ex) { "Client negotiation failure (#{remote_address}) #{ex.inspect}" }
    ensure
      socket.close rescue nil
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
