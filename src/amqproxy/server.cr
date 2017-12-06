require "socket"
require "openssl"
require "./amqp"
require "./token_bucket"
require "./pool"
require "./client"
require "./upstream"

module AMQProxy
  class Server
    @closing = false

    def initialize(config : Hash(String, String))
      puts "Proxy upstream: #{config["upstream"]}"

      @pool = Pool(Upstream).new(config["maxConnections"].to_i) do
        Upstream.new(config["upstream"], config.fetch("defaultPrefetch", "0").to_u16)
      end

      listen = config["listen"]
      @socket = TCPServer.new(listen["address"], listen["port"].to_i)
      puts "Proxy listening on #{@socket.local_address}"
    end

    def listen
      until @closing
        if client = @socket.accept?
          print "Client connection accepted from ", client.remote_address, "\n"
          spawn handle_connection(client)
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
      @socket && @socket.as(TCPServer).close
    end

    def handle_connection(socket)
      client = Client.new(socket)
      #bucket = TokenBucket.new(100, 5.seconds)
      @pool.borrow do |upstream|
        begin
          loop do
            idx, frame = Channel.select([upstream.next_frame, client.next_frame])
            case idx
            when 0
              break if frame.nil?
              client.write frame.to_slice
            when 1
              if frame.nil?
                upstream.close_all_open_channels
                break
              else
                upstream.write frame.to_slice
              end
            end
          end
        rescue ex : IO::EOFError | Errno
          puts "Client loop #{ex.inspect}"
        ensure
          puts "Client connection closed"
          socket.close
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
