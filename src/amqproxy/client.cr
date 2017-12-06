require "socket"

module AMQProxy
  class Client
    def initialize(@socket : (TCPSocket | OpenSSL::SSL::Socket::Server))
      negotiate_client(@socket)
      @channel = Channel(AMQP::Frame?).new
      spawn decode_frames
    end

    def decode_frames
      loop do
        frame = AMQP::Frame.decode @socket
        case frame
        when AMQP::Connection::Close
          @socket.write AMQP::Connection::CloseOk.new.to_slice
          @channel.send nil
          break
        end
        @channel.send frame
      end
    rescue ex : Errno | IO::Error | OpenSSL::SSL::Error
      puts "Client conn closed #{ex.inspect}"
      @channel.send nil
    end

    def next_frame
      @channel.receive_select_action
    end

    def write(bytes : Slice(UInt8))
      @socket.write bytes
    rescue ex : Errno | IO::Error | OpenSSL::SSL::Error
      puts "Client conn closed: #{ex.message}"
      @channel.send nil
    end

    private def negotiate_client(socket)
      start = Bytes.new(8)
      bytes = socket.read_fully(start)

      if start != AMQP::PROTOCOL_START
        socket.write AMQP::PROTOCOL_START
        socket.close
        raise IO::EOFError.new("Invalid protocol start")
      end

      start = AMQP::Connection::Start.new
      socket.write start.to_slice

      start_ok = AMQP::Frame.decode socket

      tune = AMQP::Connection::Tune.new(frame_max: 4096_u32, channel_max: 0_u16, heartbeat: 60_u16)
      socket.write tune.to_slice

      tune_ok = AMQP::Frame.decode socket

      open = AMQP::Frame.decode socket

      open_ok = AMQP::Connection::OpenOk.new
      socket.write open_ok.to_slice
    end
  end
end
