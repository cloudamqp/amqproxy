require "socket"
require "openssl"
require "log"
require "./client"
require "./channel_pool"

module AMQProxy
  class Upstream
    Log = ::Log.for(self)
    @socket : AMQ::Protocol::Stream
    @io : TCPSocket | OpenSSL::SSL::Socket::Client
    # nil for a channel that timed out while opening, kept until the server
    # confirms that it's closed so that the id isn't reused
    @channels = Hash(UInt16, DownstreamChannel?).new
    # Gets nil on Channel#OpenOk, or the Channel#Close the server refused with
    @opening = Hash(UInt16, Channel(AMQ::Protocol::Frame::Channel::Close?)).new
    @channels_lock = Mutex.new
    @lock = Mutex.new
    @remote_address : String
    getter channel_max : UInt16
    @frame_max : UInt32
    @heartbeat : UInt16
    @last_write = Time.instant
    @done = Channel(Nil).new

    # The largest frame we accept from the upstream server, we never negotiate
    # a higher value in Connection#TuneOk
    FRAME_MAX = 131_072_u32

    def initialize(@host : String, @port : Int32, @tls_ctx : OpenSSL::SSL::Context::Client?, credentials, @max_upstream_channels : UInt16 = UInt16::MAX,
                   connect_timeout : Time::Span? = nil)
      tcp_socket = TCPSocket.new(@host, @port, connect_timeout: connect_timeout)
      tcp_socket.sync = false
      tcp_socket.keepalive = true
      tcp_socket.tcp_keepalive_idle = 60
      tcp_socket.tcp_keepalive_count = 3
      tcp_socket.tcp_keepalive_interval = 10
      tcp_socket.tcp_nodelay = true
      @remote_address = tcp_socket.remote_address.to_s
      tcp_socket.read_timeout = connect_timeout # also limits the TLS and AMQP handshakes
      @io =
        if tls_ctx = @tls_ctx
          tls_socket = OpenSSL::SSL::Socket::Client.new(tcp_socket, tls_ctx, hostname: @host)
          tls_socket.sync_close = true
          tls_socket
        else
          tcp_socket
        end
      @socket = AMQ::Protocol::Stream.new(@io, FRAME_MAX)
      tune_ok = start(credentials)
      tcp_socket.read_timeout = nil
      @channel_max = tune_ok.channel_max
      @frame_max = tune_ok.frame_max
      @heartbeat = tune_ok.heartbeat
      if @heartbeat > 0
        spawn heartbeat_loop((@heartbeat / 2).seconds), name: "Upstream#heartbeat_loop"
      end
    end

    # Send heartbeats when the connection is idle, the server expects them
    # regardless of whether it sends any itself
    private def heartbeat_loop(interval : Time::Span)
      loop do
        select
        when @done.receive?
          break
        when timeout interval
          next if Time.instant - @last_write < interval
          send AMQ::Protocol::Frame::Heartbeat.new
        end
      end
    rescue WriteError
      # connection is gone, read_loop will clean up
    end

    # Takes a free channel id, which counts towards `#channels` from now on,
    # the channel must then be opened with `#open_channel`
    def create_channel(downstream_channel : DownstreamChannel) : UpstreamChannel
      @channels_lock.synchronize do
        raise ChannelMaxReached.new if @channels.size >= @channel_max
        1_u16.upto(@channel_max) do |i|
          unless @channels.has_key?(i)
            @channels[i] = downstream_channel
            return UpstreamChannel.new(self, i)
          end
        end
        raise ChannelMaxReached.new
      end
    end

    # Sends Channel#Open and waits for the server to answer
    def open_channel(upstream_channel : UpstreamChannel, timeout : Time::Span) : Nil
      id = upstream_channel.channel
      opened = Channel(AMQ::Protocol::Frame::Channel::Close?).new(1)
      @channels_lock.synchronize { @opening[id] = opened }
      send AMQ::Protocol::Frame::Channel::Open.new(id)
      select
      when refused = opened.receive
      when @done.receive?
        raise Error.new "Upstream connection closed while opening channel"
      when timeout(timeout)
        if abandon_channel(id)
          raise ChannelOpenError.new(500_u16, "UPSTREAM_ERROR - Timeout waiting for upstream to open channel")
        end
        refused = opened.receive # answered just as the timeout fired
      end
      raise ChannelOpenError.new(refused.reply_code, refused.reply_text) if refused
    end

    # The server may still open the channel, so close it, but stop
    # forwarding its frames as the client never got Channel#OpenOk.
    # False if the server has already answered.
    private def abandon_channel(id : UInt16) : Bool
      @channels_lock.synchronize do
        return false unless @opening.delete(id)
        @channels[id] = nil
      end
      close_channel(id, 200_u16, "Timeout waiting for Channel#OpenOk")
      true
    rescue WriteError
      true # connection is gone, read_loop will clean up
    end

    def close_channel(id, code, reason)
      send AMQ::Protocol::Frame::Channel::Close.new(id, code, reason, 0_u16, 0_u16)
    end

    def channels
      @channels.size
    end

    # Frames from upstream (to client)
    def read_loop(socket = @socket) # ameba:disable Metrics/CyclomaticComplexity
      Log.context.set(upstream: @remote_address)
      i = 0u64
      loop do
        case frame = socket.next_frame
        when AMQ::Protocol::Frame::Heartbeat then send frame
        when AMQ::Protocol::Frame::Connection::Close
          Log.error { "Upstream closed connection: #{frame.reply_text} #{frame.reply_code}" }
          close_all_downstream_client_connections(frame.reply_code, frame.reply_text)
          begin
            send AMQ::Protocol::Frame::Connection::CloseOk.new
          rescue WriteError
          end
          return
        when AMQ::Protocol::Frame::Connection::CloseOk then return
        when AMQ::Protocol::Frame::Connection::Blocked,
             AMQ::Protocol::Frame::Connection::Unblocked
          send_to_all_clients(frame)
        when AMQ::Protocol::Frame::Channel::OpenOk
          opening, downstream_channel = @channels_lock.synchronize do
            downstream = @channels[frame.channel]?
            # without a client to tell, the waiter times out and closes it
            {downstream && @opening.delete(frame.channel), downstream}
          end
          if opening && downstream_channel
            opening.send(nil)
            # here, so that the client gets it before any other frame on the channel
            downstream_channel.opened(UpstreamChannel.new(self, frame.channel))
          end
        when AMQ::Protocol::Frame::Channel::Close
          send AMQ::Protocol::Frame::Channel::CloseOk.new(frame.channel)
          opening, downstream_channel = @channels_lock.synchronize do
            {@opening.delete(frame.channel), @channels.delete(frame.channel)}
          end
          if opening
            opening.send(frame) # the client is still waiting for Channel#OpenOk
          elsif downstream_channel
            downstream_channel.write frame
          end
        when AMQ::Protocol::Frame::Channel::CloseOk # when client requested channel close
          if downstream_channel = @channels_lock.synchronize { @channels.delete(frame.channel) }
            downstream_channel.write(frame)
          end
        else
          if downstream_channel = @channels_lock.synchronize { @channels[frame.channel]? }
            downstream_channel.write(frame)
          else
            Log.debug { "Frame for unmapped channel from upstream: #{frame}" }
          end
        end
        Fiber.yield if (i &+= 1) % 4096 == 0
      end
    rescue ex : IO::Error | OpenSSL::SSL::Error | AMQ::Protocol::Error
      Log.info { "Connection error #{ex.inspect}" } unless @io.closed?
    ensure
      @done.close
      @io.close rescue nil
      close_all_downstream_client_connections
    end

    private def close_all_downstream_client_connections(code = 500_u16, reason = "UPSTREAM_ERROR")
      clients = Set(Client).new
      @channels_lock.synchronize do
        return if @channels.empty?
        Log.debug { "Upstream connection closed, closing #{@channels.size} client connections" }
        @channels.each_value do |downstream_connection|
          clients << downstream_connection.client if downstream_connection
        end

        clients.each do |client|
          client.close_connection(code, reason)
        end
        @channels.clear
      end
    end

    private def send_to_all_clients(frame : AMQ::Protocol::Frame::Connection)
      Log.debug { "Sending broadcast frame to all client connections" }
      clients = Set(Client).new
      @channels_lock.synchronize do
        @channels.each_value do |downstream_channel|
          clients << downstream_channel.client if downstream_channel
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
        @last_write = Time.instant
      rescue ex : IO::Error | OpenSSL::SSL::Error
        @io.close rescue nil
        raise WriteError.new "Error writing to upstream", ex
      end
    end

    private def expect_more_publish_frames?(frame) : Bool
      case frame
      when AMQ::Protocol::Frame::Basic::Publish then true
      when AMQ::Protocol::Frame::Header         then frame.body_size != 0
      else                                           false
      end
    end

    def close(reason = "")
      @lock.synchronize do
        close = AMQ::Protocol::Frame::Connection::Close.new(200_u16, reason, 0_u16, 0_u16)
        close.to_io(@socket, IO::ByteFormat::NetworkEndian)
        @socket.flush
      rescue ex : IO::Error | OpenSSL::SSL::Error
        @io.close
        raise WriteError.new "Error writing Connection#Close to upstream", ex
      end
    end

    def closed?
      @io.closed?
    end

    private def start(credentials) : AMQ::Protocol::Frame::Connection::TuneOk
      @socket.write AMQ::Protocol::PROTOCOL_START_0_9_1.to_slice
      @socket.flush

      # assert correct frame type
      @socket.next_frame.as(AMQ::Protocol::Frame::Connection::Start)

      response = "\u0000#{credentials.user}\u0000#{credentials.password}"
      start_ok = AMQ::Protocol::Frame::Connection::StartOk.new(response: response, client_properties: ClientProperties, mechanism: "PLAIN", locale: "en_US")
      @socket.write_bytes start_ok, IO::ByteFormat::NetworkEndian
      @socket.flush

      case tune = @socket.next_frame
      when AMQ::Protocol::Frame::Connection::Tune
        server_max = tune.channel_max.zero? ? UInt16::MAX : tune.channel_max
        max_upstream_channels = @max_upstream_channels.zero? ? UInt16::MAX : @max_upstream_channels
        channel_max = Math.min(server_max, max_upstream_channels)
        frame_max = tune.frame_max.zero? ? FRAME_MAX : Math.min(FRAME_MAX, tune.frame_max)
        tune_ok = AMQ::Protocol::Frame::Connection::TuneOk.new(channel_max, frame_max, tune.heartbeat)
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

      case f = @socket.next_frame
      when AMQ::Protocol::Frame::Connection::OpenOk
      when AMQ::Protocol::Frame::Connection::Close
        send_close_ok
        raise AccessError.new f.reply_text
      else
        raise "Unexpected frame on connection to upstream: #{f}"
      end
      tune_ok
    rescue ex : AccessError
      raise ex
    rescue ex
      @io.close
      raise Error.new ex.message, cause: ex
    end

    private def send_close_ok
      @socket.write_bytes AMQ::Protocol::Frame::Connection::CloseOk.new, IO::ByteFormat::NetworkEndian
      @socket.flush
      @io.close # Stream#close is a noop
    end

    ClientProperties = AMQ::Protocol::Table.new({
      connection_name: System.hostname,
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

    # Only this channel failed, the connection is still usable
    class ChannelOpenError < Error
      getter reply_code : UInt16
      getter reply_text : String

      def initialize(@reply_code : UInt16, @reply_text : String)
        super(@reply_text)
      end
    end
  end
end
