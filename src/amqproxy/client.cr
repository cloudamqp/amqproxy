require "socket"
require "amq-protocol"

module AMQProxy
  struct Client
    @closed = false

    def initialize(@socket : (TCPSocket | OpenSSL::SSL::Socket::Server))
      @started = Time.utc
    end

    def read_loop(upstream : Upstream)
      socket = @socket
      loop do
        AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian) do |frame|
          case frame
          when AMQ::Protocol::Frame::Heartbeat
            socket.write_bytes frame, IO::ByteFormat::NetworkEndian
            socket.flush
          when AMQ::Protocol::Frame::Connection::CloseOk
            return
          else
            if response_frame = upstream.write frame
              socket.write_bytes response_frame, IO::ByteFormat::NetworkEndian
              socket.flush
              return if response_frame.is_a? AMQ::Protocol::Frame::Connection::CloseOk
            end
          end
        end
      end
    rescue ex : Upstream::WriteError
      upstream_disconnected
    rescue ex : IO::EOFError
      raise Error.new("Client disconnected", ex) unless @closed
    rescue ex
      raise ReadError.new "Client read error", ex
    ensure
      @closed = true
      @socket.close rescue nil
    end

    # Send frame to client
    def write(frame : AMQ::Protocol::Frame)
      socket = @socket
      return if socket.closed?
      frame.to_io(socket, IO::ByteFormat::NetworkEndian)
      socket.flush
      case frame
      when AMQ::Protocol::Frame::Connection::CloseOk
        @closed = true
        socket.close
      end
    rescue ex : Socket::Error | OpenSSL::SSL::Error
      raise WriteError.new "Error writing to client", ex
    end

    def upstream_disconnected
      write AMQ::Protocol::Frame::Connection::Close.new(0_u16,
        "UPSTREAM_ERROR",
        0_u16, 0_u16)
    rescue WriteError
    end

    def close
      write AMQ::Protocol::Frame::Connection::Close.new(0_u16,
        "AMQProxy shutdown",
        0_u16, 0_u16)
    end

    def close_socket
      @closed = true
      @socket.close rescue nil
    end

    def socket
      @socket
    end

    def lifetime
      Time.utc - @started
    end

    def self.negotiate(socket)
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

      AMQ::Protocol::Frame.from_io socket, IO::ByteFormat::NetworkEndian do |_tune_ok|
      end

      vhost = ""
      AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian) do |frame|
        open = frame.as(AMQ::Protocol::Frame::Connection::Open)
        vhost = open.vhost
      end

      open_ok = AMQ::Protocol::Frame::Connection::OpenOk.new
      open_ok.to_io(socket, IO::ByteFormat::NetworkEndian)
      socket.flush

      {vhost, user, password}
    rescue ex
      raise NegotiationError.new "Client negotiation failed", ex
    end

    class Error < Exception; end

    class ReadError < Error; end

    class WriteError < Error; end

    class NegotiationError < Error; end
  end
end
