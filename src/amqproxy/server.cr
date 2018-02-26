require "socket"
require "openssl"
require "./amqp"
require "./pool"
require "./client"
require "./upstream"

module AMQProxy
  class Server
    @running = true

    def initialize(upstream_host, upstream_port, upstream_tls)
      print "Proxy upstream: #{upstream_host}:#{upstream_port} "
      print "TLS" if upstream_tls
      print "\n"
      @pool = Pool.new(upstream_host, upstream_port, upstream_tls)
      @client_connections = 0
    end

    getter :client_connections

    def upstream_connections
      @pool.size
    end

    def listen(address, port)
      TCPServer.open(address, port) do |socket|
        socket.keepalive = true
        socket.linger = 0
        socket.tcp_nodelay = true
        puts "Proxy listening on #{socket.local_address}"
        while @running
          if client = socket.accept?
            spawn handle_connection(client, client.remote_address)
          else
            break
          end
        end
      end
    end

    def listen_tls(address, port, cert_path : String, key_path : String)
      TCPServer.open(address, port) do |socket|
        socket.keepalive = true
        socket.linger = 0
        socket.tcp_nodelay = true
        context = OpenSSL::SSL::Context::Server.new
        context.private_key = key_path
        context.certificate_chain = cert_path
        puts "Proxy listening on #{socket.local_address}:#{port} (TLS)"

        while @running
          if client = @socket.accept?
            print "Client connection accepted from ", client.remote_address, "\n"
            begin
              ssl_client = OpenSSL::SSL::Socket::Server.new(client, context)
              ssl_client.sync_close = ssl_client.sync = true
              spawn handle_connection(ssl_client, client.remote_address)
            rescue e : OpenSSL::SSL::Error
              print "Error accepting OpenSSL connection from ", client.remote_address, ": ", e.message, "\n"
            end
          else
            break
          end
        end
      end
    end

    def close
      @running = false
    end

    def handle_connection(socket, remote_address)
      @client_connections += 1
      c = Client.new(socket)
      print "Client connection accepted from ", remote_address, "\n"
      @pool.borrow(c.user, c.password, c.vhost) do |u|
        if u.nil?
          c.write AMQP::Connection::Close.new(403_u16, "ACCESS_REFUSED",
                                              0_u16, 0_u16)
          next
        end
        loop do
          idx, frame = Channel.select([u.next_frame, c.next_frame])
          case idx
          when 0 # Frame from upstream, to client
            if frame.nil?
              c.write AMQP::Connection::Close.new(302_u16, "UPSTREAM_ERROR",
                                                  0_u16, 0_u16)
              break
            end
            c.write frame
          when 1 # Frame from client, to upstream
            if frame.nil?
              u.client_disconnected
              break
            end
            u.write frame
          end
        end
      end
    rescue ex : Errno | IO::Error | OpenSSL::SSL::Error
      print "Client connection error from ", remote_address, ": ",
        ex.inspect_with_backtrace, "\n"
    ensure
      print "Client connection closed from ", remote_address, "\n"
      socket.close
      @client_connections -= 1
    end
  end
end
