require "socket"
require "openssl"
require "uri"

module AMQProxy
  class Upstream
    def initialize(url : String, default_prefetch : UInt16)
      uri = URI.parse url
      @tls = (uri.scheme == "amqps").as(Bool)
      @host = uri.host || "localhost"
      @port = uri.port || (@tls ? 5671 : 5672)

      @default_prefetch = default_prefetch

      @socket = uninitialized IO
      @outbox = Channel(AMQP::Frame?).new
      connect!
      spawn decode_frames
    end

    def connect!
      tcp_socket = TCPSocket.new(@host, @port)
      @socket = if @tls
                  context = OpenSSL::SSL::Context::Client.new
                  OpenSSL::SSL::Socket::Client.new(tcp_socket, context)
                else
                  tcp_socket
                end
      negotiate_server
      puts "Connected to upstream #{@host}:#{@port}"
    end

    def decode_frames
      loop do
        frame = AMQP::Frame.decode @socket
        case frame
        when AMQP::Channel::OpenOk
          if @default_prefetch > 0_u16
            write AMQP::Basic::Qos.new(frame.channel, 0_u32, @default_prefetch, false).to_slice
            nextFrame = AMQP::Frame.decode @socket
            if nextFrame.class != AMQP::Basic::QosOk || nextFrame.channel != frame.channel
              raise "Unexpected frame after setting default prefetch: #{nextFrame.class}"
            end
          end
        end
        @outbox.send frame
      end
    rescue ex : Errno | IO::EOFError
      print "proxy decode frame: ", ex.message, "\n"
      @outbox.send nil
    end

    def next_frame
      @outbox.receive_select_action
    end

    def write(bytes : Slice(UInt8))
      @socket.write bytes
    rescue ex : Errno | IO::EOFError
      puts "proxy write bytes: #{ex.message}"
      @outbox.send nil
    end

    def closed?
      !@connected || @socket.closed?
    end

    private def negotiate_server
      @socket.write AMQP::PROTOCOL_START
    end
  end
end
