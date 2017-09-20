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
      @connected = false
      @reconnect = Channel(Nil).new
      @frame_channel = Channel(AMQP::Frame?).new
      @open_channels = Set(UInt16).new
      spawn connect!
    end

    def connect!
      loop do
        begin
          tcp_socket = TCPSocket.new(@host, @port)
          @socket = if @tls
                      context = OpenSSL::SSL::Context::Client.new
                      OpenSSL::SSL::Socket::Client.new(tcp_socket, context)
                    else
                      tcp_socket
                    end
          @connected = true
          negotiate_server
          spawn decode_frames
          puts "Connected to upstream #{@host}:#{@port}"
          @reconnect.receive
        rescue ex : Errno
          puts "When connecting: ", ex.message
        ensure
          @connected = false
        end
        sleep 1
      end
    end

    def decode_frames
      loop do
        frame = AMQP::Frame.decode @socket
        case frame
        when AMQP::Channel::OpenOk
          @open_channels.add frame.channel
          if @default_prefetch > 0_u16
            write AMQP::Basic::Qos.new(frame.channel, 0_u32, @default_prefetch, false).to_slice
            nextFrame = AMQP::Frame.decode @socket
            if nextFrame.class != AMQP::Basic::QosOk || nextFrame.channel != frame.channel
              raise "Unexpected frame after setting default prefetch: #{nextFrame.inspect}"
            end
          end
        when AMQP::Channel::CloseOk
          @open_channels.delete frame.channel
        end
        @frame_channel.send frame
      end
    rescue ex : Errno | IO::EOFError
      puts "proxy decode frame, reconnect: ", ex.message
      ex.backtrace.each { |l| puts l }
      @open_channels.clear
      @frame_channel.receive?
      @reconnect.send nil
    end

    def next_frame
      @frame_channel.receive_select_action
    end

    def write(bytes : Slice(UInt8))
      @socket.write bytes
    rescue ex : Errno | IO::EOFError
      puts "proxy write bytes, reconnect: #{ex.message}"
      @reconnect.send nil
      Fiber.yield
      write(bytes)
    end

    def closed?
      !@connected || @socket.closed?
    end

    def close_all_open_channels
      @open_channels.each do |ch|
        puts "Closing client channel #{ch}"
        @socket.write AMQP::Channel::Close.new(ch, 200_u16, "", 0_u16, 0_u16).to_slice
        @frame_channel.receive
      end
    end

    private def negotiate_server
      @socket.write AMQP::PROTOCOL_START
    end
  end
end
