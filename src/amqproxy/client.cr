require "socket"

module AMQProxy
  class Client
    def initialize(@socket : TCPSocket)
      negotiate_client(@socket)
      @outbox = Channel(AMQP::Frame?).new
      spawn decode_frames
    end

    def decode_frames
      loop do
        frame = AMQP::Frame.decode @socket
        case frame
        when AMQP::Connection::Close
          @socket.write AMQP::Connection::CloseOk.new.to_slice
          @outbox.send nil
          break
        end
        @outbox.send frame
      end
    rescue ex : IO::EOFError
      puts "Client conn closed #{ex.message}"
      @outbox.send nil
    end

    def next_frame
      @outbox.receive_select_action
    end

    def write(bytes : Slice(UInt8))
      @socket.write bytes
    end

    private def negotiate_client(client)
      start = Bytes.new(8)
      bytes = client.read_fully(start)

      if start != AMQP::PROTOCOL_START
        client.write AMQP::PROTOCOL_START
        client.close
        return
      end
    end
  end
end
