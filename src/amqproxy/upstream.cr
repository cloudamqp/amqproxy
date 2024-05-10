require "socket"
require "openssl"
require "log"
require "./client"
require "./channel_pool"

module AMQProxy
  class Upstream
    Log      = ::Log.for(self)
    FrameMax = 4096_u32
    @socket : IO
    @channels = Hash(UInt16, DownstreamChannel).new
    @channels_lock = Mutex.new
    @channel_max : UInt16
    @lock = Mutex.new
    @remote_address : String

    def initialize(@host : String, @port : Int32, @tls_ctx : OpenSSL::SSL::Context::Client?, credentials)
      tcp_socket = TCPSocket.new(@host, @port)
      tcp_socket.sync = false
      tcp_socket.keepalive = true
      tcp_socket.tcp_keepalive_idle = 60
      tcp_socket.tcp_keepalive_count = 3
      tcp_socket.tcp_keepalive_interval = 10
      tcp_socket.tcp_nodelay = true
      @remote_address = tcp_socket.remote_address.to_s
      @socket =
        if tls_ctx = @tls_ctx
          tls_socket = OpenSSL::SSL::Socket::Client.new(tcp_socket, tls_ctx, hostname: @host)
          tls_socket.sync_close = true
          tls_socket
        else
          tcp_socket
        end
      @channel_max = start(credentials)
    end

    def open_channel_for(downstream_channel : DownstreamChannel) : UpstreamChannel
      @channels_lock.synchronize do
        1_u16.upto(@channel_max) do |i|
          unless @channels.has_key?(i)
            @channels[i] = downstream_channel
            send AMQ::Protocol::Frame::Channel::Open.new(i)
            return UpstreamChannel.new(self, i)
          end
        end
        raise ChannelMaxReached.new
      end
    end

    def close_channel(id, code, reason)
      send AMQ::Protocol::Frame::Channel::Close.new(id, code, reason, 0_u16, 0_u16)
    end

    def channels
      @channels.size
    end

    # Frames from upstream (to client)
    def read_loop(socket = @socket) # ameba:disable Metrics/CyclomaticComplexity
      Log.context.set(remote_address: @remote_address)
      i = 0u64
      loop do
        case frame = AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian)
        when AMQ::Protocol::Frame::Heartbeat then send frame
        when AMQ::Protocol::Frame::Connection::Close
          Log.error { "Upstream closed connection: #{frame.reply_text} #{frame.reply_code}" }
          close_all_client_channels(frame.reply_code, frame.reply_text)
          begin
            send AMQ::Protocol::Frame::Connection::CloseOk.new
          rescue WriteError
          end
          return
        when AMQ::Protocol::Frame::Connection::CloseOk then return
        when AMQ::Protocol::Frame::Connection::Blocked,
             AMQ::Protocol::Frame::Connection::Unblocked
          send_to_all_clients(frame)
        when AMQ::Protocol::Frame::Channel::OpenOk # assume it always succeeds
        when AMQ::Protocol::Frame::Channel::Close
          send AMQ::Protocol::Frame::Channel::CloseOk.new(frame.channel)
          if downstream_channel = @channels_lock.synchronize { @channels.delete(frame.channel) }
            downstream_channel.write frame
          end
        when AMQ::Protocol::Frame::Channel::CloseOk # when client requested channel close
          @channels_lock.synchronize { @channels.delete(frame.channel) }
        else
          if downstream_channel = @channels_lock.synchronize { @channels[frame.channel]? }
            downstream_channel.write(frame)
          else
            Log.debug { "Frame for unmapped channel from upstream: #{frame}" }
          end
        end
        Fiber.yield if (i &+= 1) % 4096 == 0
      end
    rescue ex : IO::Error | OpenSSL::SSL::Error
      Log.info { "Connection error #{ex.inspect}" } unless socket.closed?
    ensure
      socket.close rescue nil
      close_all_client_channels
    end

    def closed?
      @socket.closed?
    end

    private def close_all_client_channels(code = 500_u16, reason = "UPSTREAM_ERROR")
      @channels_lock.synchronize do
        return if @channels.empty?
        Log.debug { "Upstream connection closed, closing #{@channels.size} client channels" }
        @channels.each_value do |downstream_channel|
          downstream_channel.close(code, reason)
        end
        @channels.clear
      end
    end

    private def send_to_all_clients(frame : AMQ::Protocol::Frame::Connection)
      Log.debug { "Sending broadcast frame to all client connections" }
      clients = Set(Client).new
      @channels_lock.synchronize do
        @channels.each_value do |downstream_channel|
          clients << downstream_channel.client
        end
      end
      clients.each do |client|
        client.write frame
      end
    end

    # Forward frames from client to upstream
    def write(frame : AMQ::Protocol::Frame) : Nil
      case frame
      when AMQ::Protocol::Frame::Connection
        raise "Connection frames should not be sent through here: #{frame}"
      when AMQ::Protocol::Frame::Channel::CloseOk
        # when upstream server requested a channel close and client confirmed
        @channels_lock.synchronize do
          @channels.delete(frame.channel)
        end
      end
      send frame
    end

    private def send(frame : AMQ::Protocol::Frame) : Nil
      @lock.synchronize do
        @socket.write_bytes frame, IO::ByteFormat::NetworkEndian
        @socket.flush unless expect_more_publish_frames?(frame)
      rescue ex : IO::Error | OpenSSL::SSL::Error
        @socket.close rescue nil
        raise WriteError.new "Error writing to upstream", ex
      end
    end

    private def expect_more_publish_frames?(frame) : Bool
      case frame
      when AMQ::Protocol::Frame::Basic::Publish
        return true
      when AMQ::Protocol::Frame::Header
        return true unless frame.body_size.zero?
      when AMQ::Protocol::Frame::BytesBody
        return true if frame.bytesize == FrameMax
      end
      false
    end

    def close(reason = "")
      @lock.synchronize do
        close = AMQ::Protocol::Frame::Connection::Close.new(200_u16, reason, 0_u16, 0_u16)
        close.to_io(@socket, IO::ByteFormat::NetworkEndian)
        @socket.flush
      rescue ex : IO::Error | OpenSSL::SSL::Error
        @socket.close
        raise WriteError.new "Error writing Connection#Close to upstream", ex
      end
    end

    def closed?
      @socket.closed?
    end

    private def start(credentials) : UInt16
      @socket.write AMQ::Protocol::PROTOCOL_START_0_9_1.to_slice
      @socket.flush

      # assert correct frame type
      AMQ::Protocol::Frame.from_io(@socket).as(AMQ::Protocol::Frame::Connection::Start)

      response = "\u0000#{credentials.user}\u0000#{credentials.password}"
      start_ok = AMQ::Protocol::Frame::Connection::StartOk.new(response: response, client_properties: ClientProperties, mechanism: "PLAIN", locale: "en_US")
      @socket.write_bytes start_ok, IO::ByteFormat::NetworkEndian
      @socket.flush

      case tune = AMQ::Protocol::Frame.from_io(@socket)
      when AMQ::Protocol::Frame::Connection::Tune
        channel_max = tune.channel_max.zero? ? UInt16::MAX : tune.channel_max
        tune_ok = AMQ::Protocol::Frame::Connection::TuneOk.new(channel_max, FrameMax, tune.heartbeat)
        @socket.write_bytes tune_ok, IO::ByteFormat::NetworkEndian
        @socket.flush
      when AMQ::Protocol::Frame::Connection::Close
        send_close_ok
        raise AccessError.new tune.reply_text
      else
        raise "Unexpected frame on connection to upstream: #{tune}"
      end

      open = AMQ::Protocol::Frame::Connection::Open.new(vhost: credentials.vhost)
      @socket.write_bytes open, IO::ByteFormat::NetworkEndian
      @socket.flush

      case f = AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian)
      when AMQ::Protocol::Frame::Connection::OpenOk
      when AMQ::Protocol::Frame::Connection::Close
        send_close_ok
        raise AccessError.new f.reply_text
      else
        raise "Unexpected frame on connection to upstream: #{f}"
      end
      channel_max
    rescue ex : AccessError
      raise ex
    rescue ex
      @socket.close
      raise Error.new ex.message, cause: ex
    end

    private def send_close_ok
      @socket.write_bytes AMQ::Protocol::Frame::Connection::CloseOk.new, IO::ByteFormat::NetworkEndian
      @socket.flush
      @socket.close
    end

    ClientProperties = AMQ::Protocol::Table.new({
      connection_name: "AMQProxy #{VERSION}",
      product:         "AMQProxy",
      version:         VERSION,
      capabilities:    {
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

    class AccessError < Error; end

    class WriteError < Error; end

    class ChannelMaxReached < Error; end
  end
end
