require "socket"
require "openssl"
require "./amqp"
require "./pool"
require "./client"
require "./upstream"

module AMQProxy
  class Server
    @closing = false

    def initialize(upstream_host, upstream_port, upstream_tls)
      print "Proxy upstream: #{upstream_host}:#{upstream_port} "
      print "TLS" if upstream_tls
      print "\n"
      @pool = Pool.new(upstream_host, upstream_port, upstream_tls)
    end

    def listen(address, port)
      TCPServer.open(address, port) do |socket|
        puts "Proxy listening on #{socket.local_address}"
        until @closing
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
        puts "Proxy listening on #{socket.local_address}:#{port}"
        context = OpenSSL::SSL::Context::Server.new
        context.private_key = key_path
        context.certificate_chain = cert_path

        until @closing
          if client = @socket.accept?
            print "Client connection accepted from ", client.remote_address, "\n"
            begin
              ssl_client = OpenSSL::SSL::Socket::Server.new(client, context, sync_close: true)
              ssl_client.sync = true
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
      @closing = true
    end

    def handle_connection(socket, remote_address)
      c = Client.new(socket)
      print "Client connection accepted from ", remote_address, "\n"
      @pool.borrow(c.user, c.password, c.vhost) do |u|
        if u.nil?
          c.write AMQP::Connection::Close.new(403_u16, "ACCESS_REFUSED", 0_u16, 0_u16).to_slice
          next
        end
        loop do
          idx, frame = Channel.select([u.next_frame, c.next_frame])
          case idx
          when 0 # Upstream frame
            if frame.nil?
              c.write AMQP::Connection::Close.new(302_u16, "Connection to upstream closed", 0_u16, 0_u16).to_slice
              break
            end
            c.write frame.to_slice
          when 1 # Client frame
            if frame.nil?
              u.close_all_open_channels
              break
            end
            u.write frame.to_slice
          end
        end
      end
    rescue ex : Errno | IO::Error | OpenSSL::SSL::Error
      print "Client connection error from ", remote_address, ": ", ex.inspect_with_backtrace, "\n"
    ensure
      print "Client connection closed from ", remote_address, "\n"
      socket.close
    end
  end
end
