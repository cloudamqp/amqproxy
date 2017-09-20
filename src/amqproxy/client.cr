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
    rescue ex : IO::Error | IO::EOFError | OpenSSL::SSL::Error
      puts "Client conn closed: #{ex.message}"
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
