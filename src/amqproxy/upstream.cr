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
      @user = uri.user || "guest"
      @password = uri.password || "guest"
      path = uri.path || ""
      @vhost = path.empty? ? "/" : path[1..-1]

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
      print "Connected to upstream ", tcp_socket.remote_address, "\n"
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

    def close
      @socket.close
    end

    def closed?
      @socket.closed?
    end

    private def negotiate_server
      @socket.write AMQP::PROTOCOL_START

      start = AMQP::Frame.decode @socket
      assert_frame_type start, AMQP::Connection::Start

      start_ok = AMQP::Connection::StartOk.new(response: "\u0000#{@user}\u0000#{@password}")
      @socket.write start_ok.to_slice

      tune = AMQP::Frame.decode @socket
      assert_frame_type tune, AMQP::Connection::Tune

      channel_max = tune.as(AMQP::Connection::Tune).channel_max
      frame_max = tune.as(AMQP::Connection::Tune).frame_max
      tune_ok = AMQP::Connection::TuneOk.new(channel_max, frame_max, 0_u16)
      @socket.write tune_ok.to_slice

      open = AMQP::Connection::Open.new(vhost: @vhost)
      @socket.write open.to_slice

      open_ok = AMQP::Frame.decode @socket
      assert_frame_type open_ok, AMQP::Connection::OpenOk
    end

    private def assert_frame_type(frame, clz)
      unless frame.class == clz
        raise "Expected frame #{clz} but got: #{frame.inspect}"
      end
    end
  end
end
