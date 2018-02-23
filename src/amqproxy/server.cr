require "socket"
require "openssl"
require "uri"
require "./amqp"
require "./pool"
require "./client"
require "./upstream"

module AMQProxy
  class Server
    @closing = false

    def initialize(config : Hash(String, Hash(String, String)))
      upstream = config["server"]["upstream"]
      u = URI.parse upstream
      tls = u.scheme == "amqps"
      port = u.port || (tls ? 5671 : 5672)
      max_connections = config["server"]["maxConnections"].to_i
      listen = config["listen"]
      puts "Proxy upstream: #{config["server"]["upstream"]}"
      @pool = Pool.new(max_connections, u.host || "", port, tls)
      @socket = TCPServer.new(listen["address"], listen["port"].to_i)
      puts "Proxy listening on #{@socket.local_address}"
    end

    def listen
      until @closing
        if client = @socket.accept?
          spawn handle_connection(client, client.remote_address)
        else
          break
        end
      end
    end

    def listen_tls(cert_path : String, key_path : String)
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

    def close
      @closing = true
      @socket.close
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
