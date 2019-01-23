require "socket"
require "amq-protocol"

module AMQProxy
  class Client
    getter vhost, user, password
    @vhost : String
    @user : String
    @password : String

    def initialize(@socket : (TCPSocket | OpenSSL::SSL::Socket::Server))
      @vhost, @user, @password = negotiate_client(@socket)
      @outbox = Channel(AMQ::Protocol::Frame?).new(1)
      spawn decode_frames
    end

    def decode_frames
      loop do
        AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) do |frame|
          @outbox.send frame
        end
      end
    rescue ex : Errno | IO::Error | OpenSSL::SSL::Error
      @outbox.send nil
    end

    def next_frame
      @outbox.receive_select_action
    end

    def write(frame : AMQP::Frame)
      frame.to_io(@socket, IO::ByteFormat::NetworkEndian)
      @socket.flush
      case frame
      when AMQP::Connection::CloseOk
        @socket.close
        @outbox.send nil
      end
    rescue ex : Errno | IO::Error | OpenSSL::SSL::Error
      @outbox.send nil
    end

    private def negotiate_client(socket) : Array(String)
      proto = uninitialized UInt8[8]
      socket.read_fully(proto.to_slice)

      if proto != AMQ::Protocol::PROTOCOL_START_0_9_1 && proto != AMQ::Protocol::PROTOCOL_START_0_9
        socket.write AMQ::Protocol::PROTOCOL_START_0_9_1.to_slice
        socket.flush
        socket.close
        raise IO::EOFError.new("Invalid protocol start")
      end

      start = AMQ::Protocol::Frame::Connection::Start.new
      start.to_io(socket, IO::ByteFormat::NetworkEndian)
      socket.flush

      user = password = ""
      AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian) do |frame|
        start_ok = frame.as(AMQ::Protocol::Frame::Connection::StartOk)
        case start_ok.mechanism
        when "PLAIN"
          resp = start_ok.response
          i = resp.index('\u0000', 1).not_nil!
          user = resp[1...i]
          password = resp[(i + 1)..-1]
        when "AMQPLAIN"
          io = IO::Memory.new(start_ok.response)
          tbl = AMQ::Protocol::Table.from_io(io, IO::ByteFormat::NetworkEndian,
                                             start_ok.response.size.to_u32)
          user = tbl["LOGIN"].as(String)
          password = tbl["PASSWORD"].as(String)
        else "Unsupported authentication mechanism: #{start_ok.mechanism}"
        end
      end

      tune = AMQ::Protocol::Frame::Connection::Tune.new(frame_max: 131072_u32, channel_max: 0_u16, heartbeat: 600_u16)
      tune.to_io(socket, IO::ByteFormat::NetworkEndian)
      socket.flush

      AMQ::Protocol::Frame.from_io socket, IO::ByteFormat::NetworkEndian do |tune_ok|
      end

      vhost = ""
      AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian) do |frame|
        open = frame.as(AMQ::Protocol::Frame::Connection::Open)
        vhost = open.vhost
      end

      open_ok = AMQ::Protocol::Frame::Connection::OpenOk.new
      open_ok.to_io(socket, IO::ByteFormat::NetworkEndian)
      socket.flush

      [vhost, user, password]
    end
  end
end
