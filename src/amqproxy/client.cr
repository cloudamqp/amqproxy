require "socket"

module AMQProxy
  class Client
    def initialize(@socket : (TCPSocket | OpenSSL::SSL::Socket::Server))
      negotiate_client(@socket)
      @outbox = Channel(AMQP::Frame?).new
      spawn decode_frames
    end

    def decode_frames
      loop do
        @outbox.send AMQP::Frame.decode(@socket)
      end
    rescue ex : Errno | IO::Error | OpenSSL::SSL::Error
      puts "Client conn closed: #{ex.message}"
      @outbox.send nil
    end

    def next_frame
      @outbox.receive_select_action
    end

    def write(bytes : Slice(UInt8))
      @socket.write bytes
    rescue ex : Errno | IO::Error | OpenSSL::SSL::Error
      puts "Client conn closed: #{ex.message}"
      @outbox.send nil
    end

    private def negotiate_client(socket)
      start = Bytes.new(8)
      bytes = socket.read_fully(start)

      if start != AMQP::PROTOCOL_START
        socket.write AMQP::PROTOCOL_START
        socket.close
        raise IO::EOFError.new("Invalid protocol start")
      end
    end
  end
end
