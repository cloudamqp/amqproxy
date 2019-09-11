require "socket"
require "amq-protocol"

module AMQProxy
  class Client
    getter vhost, user, password, close_channel
    @vhost : String
    @user : String
    @password : String

    def initialize(@socket : (TCPSocket | OpenSSL::SSL::Socket::Server), @log : Logger)
      @vhost, @user, @password = negotiate_client(@socket)
      @close_channel = Channel(Nil).new
    end

    def decode_frames(upstream : Upstream)
      loop do
        AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) do |frame|
          case frame
          when AMQ::Protocol::Frame::Heartbeat
            frame.to_io(@socket, IO::ByteFormat::NetworkEndian)
            @socket.flush
          when AMQ::Protocol::Frame::Connection::CloseOk
            @socket.close
            return
          else
            if response_frame = upstream.write frame
              response_frame.to_io(@socket, IO::ByteFormat::NetworkEndian)
              @socket.flush
            end
          end
        end
      end
    rescue ex : Errno | IO::Error | OpenSSL::SSL::Error
      nil
    ensure
      @close_channel.send nil
    end

    def write(frame : AMQ::Protocol::Frame)
      return if @socket.closed?
      frame.to_io(@socket, IO::ByteFormat::NetworkEndian)
      @socket.flush
      case frame
      when AMQ::Protocol::Frame::Connection::CloseOk
        @socket.close
        @close_channel.send nil
      end
    rescue ex : Errno | IO::Error | OpenSSL::SSL::Error
      @close_channel.send nil
    end

    def upstream_disconnected
      f = AMQ::Protocol::Frame::Connection::Close.new(302_u16,
                                                      "UPSTREAM_ERROR",
                                                      0_u16, 0_u16)
      f.to_io @socket, IO::ByteFormat::NetworkEndian
      @socket.flush
    rescue IO::Error
    end

    def close
      f = AMQ::Protocol::Frame::Connection::Close.new(320_u16,
                                                      "AMQProxy shutdown",
                                                      0_u16, 0_u16)
      f.to_io @socket, IO::ByteFormat::NetworkEndian
      @socket.flush
    end

    private def negotiate_client(socket)
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
        else raise "Unsupported authentication mechanism: #{start_ok.mechanism}"
        end
      end

      tune = AMQ::Protocol::Frame::Connection::Tune.new(frame_max: 131072_u32, channel_max: 0_u16, heartbeat: 0_u16)
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

      { vhost, user, password }
    end
  end
end
