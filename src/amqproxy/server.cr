require "socket"
require "openssl"
require "./amqp"
require "./client"
require "./upstream"

module AMQProxy
  class Server
    @upstream_url : String
    @default_prefetch : UInt16
    @closing = false

    def initialize(config : Hash(String, String))
      @upstream_url = config["upstream"].to_s
      @default_prefetch = config.fetch("defaultPrefetch", "0").to_u16
      @socket = uninitialized TCPServer
      puts "Proxy upstream: #{config["upstream"]}"
    end

    def listen(address : String, port : Int)
      @socket = TCPServer.new(address, port)
      puts "Proxy listening on #{@socket.local_address}"
      until @closing
        if client = @socket.accept?
          print "Client connection accepted from ", client.remote_address, "\n"
          spawn handle_connection(client)
        else
          break
        end
      end
    end

    def listen_tls(address : String, port : Int, cert_path : String, key_path : String)
      @socket = TCPServer.new(address, port)
      puts "Proxy listening on #{@socket.local_address} (TLS)"

      context = OpenSSL::SSL::Context::Server.new
      context.private_key = key_path
      context.certificate_chain = cert_path

      until @closing
        if client = @socket.accept?
          print "Client connection accepted from ", client.remote_address, "\n"
          begin
            ssl_client = OpenSSL::SSL::Socket::Server.new(client, context, sync_close: true)
            ssl_client.sync = true
            spawn handle_connection(ssl_client)
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
