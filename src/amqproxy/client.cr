require "socket"

module AMQProxy
  class Client
    getter vhost, user, password
    @vhost : String
    @user : String
    @password : String

    def initialize(@socket : (TCPSocket | OpenSSL::SSL::Socket::Server))
      @vhost, @user, @password = negotiate_client(@socket)
      @outbox = Channel(AMQP::Frame?).new(1)
      spawn decode_frames
    end

    def decode_frames
      loop do
        frame = AMQP::Frame.decode @socket
        @outbox.send frame
      end
    rescue ex : Errno | IO::Error | OpenSSL::SSL::Error
      @outbox.send nil
    end

    def next_frame
      @outbox.receive_select_action
    end

    def write(frame : AMQP::Frame)
      @socket.write frame.to_slice
      case frame
      when AMQP::Connection::CloseOk
        @socket.close
        @outbox.send nil
      end
    rescue ex : Errno | IO::Error | OpenSSL::SSL::Error
      @outbox.send nil
    end

    private def negotiate_client(socket) : Array(String)
      start = Bytes.new(8)
      bytes = socket.read_fully(start)

      if start != AMQP::PROTOCOL_START && start != AMQP::PROTOCOL_START_ALT
        socket.write AMQP::PROTOCOL_START
        socket.close
        raise IO::EOFError.new("Invalid protocol start")
      end

      start = AMQP::Connection::Start.new
      socket.write start.to_slice

      start_ok = AMQP::Frame.decode(socket).as(AMQP::Connection::StartOk)
      user = password = ""
      case start_ok.mechanism
      when "PLAIN"
        resp = start_ok.response
        i = resp.index('\u0000', 1).not_nil!
        user = resp[1...i]
        password = resp[(i + 1)..-1]
      when "AMQPLAIN"
        io = AMQP::IO.new(start_ok.response.to_slice)
        tbl = io.read_table(io.size.to_u32)
        user = tbl["LOGIN"].as(String)
        password = tbl["PASSWORD"].as(String)
      else "Unsupported authentication mechanism: #{start_ok.mechanism}"
      end

      tune = AMQP::Connection::Tune.new(frame_max: 4096_u32, channel_max: 0_u16, heartbeat: 600_u16)
      socket.write tune.to_slice

      tune_ok = AMQP::Frame.decode socket

      open = AMQP::Frame.decode(socket).as(AMQP::Connection::Open)

      open_ok = AMQP::Connection::OpenOk.new
      socket.write open_ok.to_slice

      [open.vhost, user, password]
    end
  end
end
