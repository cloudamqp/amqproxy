require "socket"
require "openssl"
require "./amqp"
require "./client"
require "./upstream"

module AMQProxy
  class Server
    @upstream_url : String
    @default_prefetch : UInt16

    def initialize(config : Hash(String, String))
      @upstream_url = config["upstream"].to_s
      @default_prefetch = config.fetch("defaultPrefetch", "0").to_u16
      puts "Proxy upstream: #{config["upstream"]}"
    end

    def listen(address : String, port : Int)
      server = TCPServer.new(address, port)
      puts "Proxy listening on #{server.local_address}"
      loop do
        if socket = server.accept?
          spawn handle_connection(socket)
        else
          break
        end
      end
    end

    def listen_tls(address : String, port : Int, cert_path : String, key_path : String)
      server = TCPServer.new(address, port)
      puts "Proxy listening on #{server.local_address} (TLS)"

      context = OpenSSL::SSL::Context::Server.new
      context.private_key = key_path
      context.certificate_chain = cert_path

      loop do
        if socket = server.accept?
          begin
            ssl_socket = OpenSSL::SSL::Socket::Server.new(socket, context)
            ssl_socket.sync = true
            spawn handle_connection(ssl_socket)
          rescue e : OpenSSL::SSL::Error
            print "Error accepting OpenSSL connection: ", e.message, "\n"
          end
        else
          break
        end
      end
    end

    def close
      @closing = true
      @socket.close if @socket
    end

    def handle_connection(socket)
      client = Client.new(socket)
      upstream = Upstream.new(@upstream_url, @default_prefetch)
      loop do
        idx, frame = Channel.select([upstream.next_frame, client.next_frame])
        case idx
        when 0 # Upstream
          break if frame.nil?
          client.write frame.to_slice
        when 1 # Client
          break if frame.nil?
          upstream.write frame.to_slice
        end
      end
    rescue ex : Errno | IO::Error | OpenSSL::SSL::Error
      print "Client loop #{ex.inspect}"
    ensure
      #print "Client connection closed from ", socket.remote_address, "\n"
      puts "Closing upstream conn"
      upstream.close if upstream
      puts "Closing client conn"
      socket.close
    end
  end
end
