require "socket"
require "amq-protocol"
require "./version"
require "./upstream"
require "./records"
require "./connection_info"

module AMQProxy
  class Client
    Log = ::Log.for(self)
    getter credentials : Credentials
    getter connection_info : ConnectionInfo
    @channel_map = Hash(UInt16, UpstreamChannel?).new
    @lock = Mutex.new
    @frame_max : UInt32
    @channel_max : UInt16
    @heartbeat : UInt16
    @last_heartbeat = Time.monotonic

    def initialize(@socket : IO, @connection_info : ConnectionInfo)
      tune_ok, @credentials = negotiate(@socket)
      @frame_max = tune_ok.frame_max
      @channel_max = tune_ok.channel_max
      @heartbeat = tune_ok.heartbeat
    end

    # Keep a buffer of publish frames
    # Only send to upstream when the full message is received
    @publish_buffers = Hash(UInt16, PublishBuffer).new

    private class PublishBuffer
      getter publish : AMQ::Protocol::Frame::Basic::Publish
      property! header : AMQ::Protocol::Frame::Header?
      getter bodies = Array(AMQ::Protocol::Frame::BytesBody).new

      def initialize(@publish)
      end

      def full?
        header.body_size == @bodies.sum &.body_size
      end
    end

    private def finish_publish(channel)
      buffer = @publish_buffers[channel]
      if upstream_channel = @channel_map[channel]
        upstream_channel.write(buffer.publish)
        upstream_channel.write(buffer.header)
        buffer.bodies.each do |body|
          upstream_channel.write(body)
        end
      end
    ensure
      @publish_buffers.delete channel
    end

    # frames from enduser
    def read_loop(channel_pool, socket = @socket) # ameba:disable Metrics/CyclomaticComplexity
      Log.context.set(client: @connection_info.remote_address.to_s)
      Log.debug { "Connected" }
      i = 0u64
      if @heartbeat > 0 && socket.responds_to?(:read_timeout=)
        socket.read_timeout = (@heartbeat / 2).ceil.seconds
      end
      loop do
        frame = AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian)
        @last_heartbeat = Time.monotonic
        case frame
        when AMQ::Protocol::Frame::Heartbeat # noop
        when AMQ::Protocol::Frame::Connection::CloseOk then return
        when AMQ::Protocol::Frame::Connection::Close
          close_all_upstream_channels(frame.reply_code, frame.reply_text)
          write AMQ::Protocol::Frame::Connection::CloseOk.new
          return
        when AMQ::Protocol::Frame::Channel::Open
          raise "Channel already opened" if @channel_map.has_key? frame.channel
          upstream_channel = channel_pool.get(DownstreamChannel.new(self, frame.channel))
          @channel_map[frame.channel] = upstream_channel
          write AMQ::Protocol::Frame::Channel::OpenOk.new(frame.channel)
        when AMQ::Protocol::Frame::Channel::CloseOk
          # Server closed channel, CloseOk reply to server is already sent
          @channel_map.delete(frame.channel)
        when AMQ::Protocol::Frame::Basic::Publish
          @publish_buffers[frame.channel] = PublishBuffer.new(frame)
        when AMQ::Protocol::Frame::Header
          @publish_buffers[frame.channel].header = frame
          finish_publish(frame.channel) if frame.body_size.zero?
        when AMQ::Protocol::Frame::BytesBody
          buffer = @publish_buffers[frame.channel]
          buffer.bodies << frame
          finish_publish(frame.channel) if buffer.full?
        when frame.channel.zero?
          Log.error { "Unexpected connection frame: #{frame}" }
          close_connection(540_u16, "NOT_IMPLEMENTED", frame)
        else
          src_channel = frame.channel
          begin
            if upstream_channel = @channel_map[frame.channel]
              upstream_channel.write(frame)
            else
              # Channel::Close is sent, waiting for CloseOk
            end
          rescue ex : Upstream::WriteError
            close_channel(src_channel, 500_u16, "UPSTREAM_ERROR")
          rescue KeyError
            close_connection(504_u16, "CHANNEL_ERROR - Channel #{frame.channel} not open", frame)
          end
        end
        Fiber.yield if (i &+= 1) % 4096 == 0
      rescue ex : Upstream::AccessError
        Log.error { "Access refused, reason: #{ex.message}" }
        close_connection(403_u16, ex.message || "ACCESS_REFUSED")
      rescue ex : Upstream::Error
        Log.error(exception: ex) { "Upstream error" }
        close_connection(503_u16, "UPSTREAM_ERROR - #{ex.message}")
      rescue IO::TimeoutError
        time_since_last_heartbeat = (Time.monotonic - @last_heartbeat).total_seconds.to_i # ignore subsecond latency
        if time_since_last_heartbeat <= 1 + @heartbeat                                    # add 1s grace because of rounding
          Log.debug { "Sending heartbeat (last heartbeat #{time_since_last_heartbeat}s ago)" }
          write AMQ::Protocol::Frame::Heartbeat.new
        else
          Log.warn { "No heartbeat response in #{time_since_last_heartbeat}s (max #{1 + @heartbeat}s), closing connection" }
          return
        end
      end
    rescue ex : IO::Error
      Log.debug { "Disconnected #{ex.inspect}" }
    else
      Log.debug { "Disconnected" }
    ensure
      socket.close rescue nil
      close_all_upstream_channels
    end

    # Send frame to client, channel id should already be remapped by the caller
    def write(frame : AMQ::Protocol::Frame)
      @lock.synchronize do
        case frame
        when AMQ::Protocol::Frame::BytesBody
          # Upstream might send large frames, split them to support lower client frame_max
          pos = 0u32
          while pos < frame.body_size
            len = Math.min(@frame_max - 8, frame.body_size - pos)
            body_part = AMQ::Protocol::Frame::BytesBody.new(frame.channel, len, frame.body[pos, len])
            @socket.write_bytes body_part, IO::ByteFormat::NetworkEndian
            pos += len
          end
        else
          @socket.write_bytes frame, IO::ByteFormat::NetworkEndian
        end
        @socket.flush unless expect_more_frames?(frame)
      end
      case frame
      when AMQ::Protocol::Frame::Channel::Close
        @channel_map[frame.channel] = nil
      when AMQ::Protocol::Frame::Channel::CloseOk
        @channel_map.delete(frame.channel)
      when AMQ::Protocol::Frame::Connection::CloseOk
        @socket.close rescue nil
      end
    rescue ex : IO::Error
      # Client closed connection, suppress error
      @socket.close rescue nil
    end

    def close_connection(code, text, frame = nil)
      case frame
      when AMQ::Protocol::Frame::Method
        write AMQ::Protocol::Frame::Connection::Close.new(code, text, frame.class_id, frame.method_id)
      else
        write AMQ::Protocol::Frame::Connection::Close.new(code, text, 0_u16, 0_u16)
      end
    end

    def close_channel(id, code, reason)
      write AMQ::Protocol::Frame::Channel::Close.new(id, code, reason, 0_u16, 0_u16)
    end

    private def close_all_upstream_channels(code = 500_u16, reason = "CLIENT_DISCONNECTED")
      @channel_map.each_value do |upstream_channel|
        upstream_channel.try &.close(code, reason)
      rescue Upstream::WriteError
        Log.debug { "Upstream write error while closing client's channels" }
        next # Nothing to do
      end
      @channel_map.clear
    end

    private def expect_more_frames?(frame) : Bool
      case frame
      when AMQ::Protocol::Frame::Basic::Deliver then true
      when AMQ::Protocol::Frame::Basic::Return  then true
      when AMQ::Protocol::Frame::Basic::GetOk   then true
      when AMQ::Protocol::Frame::Header         then frame.body_size != 0
      else                                           false
      end
    end

    def close
      write AMQ::Protocol::Frame::Connection::Close.new(0_u16,
        "AMQProxy shutdown",
        0_u16, 0_u16)
      # @socket.read_timeout = 1.seconds
    end

    def close_socket
      @socket.close rescue nil
    end

    private def set_socket_options(socket = @socket)
      # For SSL sockets, configure the underlying TCP socket
      tcp_socket = socket.is_a?(OpenSSL::SSL::Socket::Server) ? socket.io : socket
      tcp_socket.sync = false
      tcp_socket.keepalive = true
      tcp_socket.tcp_nodelay = true
      tcp_socket.tcp_keepalive_idle = 60
      tcp_socket.tcp_keepalive_count = 3
      tcp_socket.tcp_keepalive_interval = 10
    end

    private def negotiate(socket = @socket)
      proto = uninitialized UInt8[8]
      socket.read_fully(proto.to_slice)

      if proto != AMQ::Protocol::PROTOCOL_START_0_9_1 && proto != AMQ::Protocol::PROTOCOL_START_0_9
        socket.write AMQ::Protocol::PROTOCOL_START_0_9_1.to_slice
        socket.flush
        socket.close
        raise IO::EOFError.new("Invalid protocol start")
      end

      start = AMQ::Protocol::Frame::Connection::Start.new(server_properties: ServerProperties)
      start.to_io(socket, IO::ByteFormat::NetworkEndian)
      socket.flush

      user = password = ""
      start_ok = AMQ::Protocol::Frame.from_io(socket).as(AMQ::Protocol::Frame::Connection::StartOk)
      case start_ok.mechanism
      when "PLAIN"
        resp = start_ok.response
        if i = resp.index('\u0000', 1)
          user = resp[1...i]
          password = resp[(i + 1)..-1]
        else
          raise "Invalid authentication information encoding"
        end
      when "AMQPLAIN"
        io = IO::Memory.new(start_ok.response)
        tbl = AMQ::Protocol::Table.from_io(io, IO::ByteFormat::NetworkEndian, start_ok.response.size.to_u32)
        user = tbl["LOGIN"].as(String)
        password = tbl["PASSWORD"].as(String)
      else raise "Unsupported authentication mechanism: #{start_ok.mechanism}"
      end

      tune = AMQ::Protocol::Frame::Connection::Tune.new(frame_max: 131072_u32, channel_max: UInt16::MAX, heartbeat: 0_u16)
      tune.to_io(socket, IO::ByteFormat::NetworkEndian)
      socket.flush

      tune_ok = AMQ::Protocol::Frame.from_io(socket).as(AMQ::Protocol::Frame::Connection::TuneOk)

      open = AMQ::Protocol::Frame.from_io(socket).as(AMQ::Protocol::Frame::Connection::Open)
      vhost = open.vhost

      open_ok = AMQ::Protocol::Frame::Connection::OpenOk.new
      open_ok.to_io(socket, IO::ByteFormat::NetworkEndian)
      socket.flush

      {tune_ok, Credentials.new(user, password, vhost)}
    end

    ServerProperties = AMQ::Protocol::Table.new({
      product:      "AMQProxy",
      version:      VERSION,
      capabilities: {
        consumer_priorities:          true,
        exchange_exchange_bindings:   true,
        "connection.blocked":         true,
        authentication_failure_close: true,
        per_consumer_qos:             true,
        "basic.nack":                 true,
        direct_reply_to:              true,
        publisher_confirms:           true,
        consumer_cancel_notify:       true,
      },
    })

    class Error < Exception; end

    class ReadError < Error; end

    class WriteError < Error; end
  end
end
