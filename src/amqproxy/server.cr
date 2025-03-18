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

    @channel_pools_lock = Mutex.new

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

    private def with_channel_pools(&)
      @channel_pools_lock.synchronize do
        yield @channel_pools
      end
    end

    def client_connections
      @clients.size
    end

    def upstream_connections
      with_channel_pools &.each_value.sum(&.connections)
    end

    def listen(address, port)
      listen(TCPServer.new(address, port))
    end

    def listen(@server : TCPServer)
      Log.info { "Proxy listening on #{server.local_address}" }

      while socket = server.accept?
        begin
          Log.debug { "Accepted new client from #{socket.remote_address} (#{socket.inspect})" }
          handle_connection(socket)
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

    private def handle_connection(socket)
      spawn(name: "Client #{socket.remote_address}") do
        c = Client.new(socket)
        channel_pool = with_channel_pools &.[c.credentials]
        remote_address = socket.remote_address
        Log.debug { "Client created for #{remote_address}" }
        active_client(c) do
          c.read_loop(channel_pool)
        end
      rescue IO::EOFError
        # Client closed connection before/while negotiating
      rescue ex # only raise from constructor, when negotating
        Log.debug(exception: ex) { "Client negotiation failure (#{remote_address}) #{ex.inspect}" }
      ensure
        socket.close rescue nil
      end
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
