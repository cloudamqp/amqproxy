require "socket"
require "./amqp"
require "./client"
require "./upstream"

module AMQProxy
  class Server
    def initialize(config : Hash(String, String))
      @upstream_url = config["upstream"]
      @default_prefetch = @config.fetch("defaultPrefetch", "0").to_u16)
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

    def handle_connection(socket)
      client = Client.new(socket)
      puts "Client connection opened"
      upstream = Upstream.new(@upstream_url, @default_prefetch)
      puts "Upstream connection established"
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
  end
end
