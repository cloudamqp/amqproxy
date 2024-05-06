require "socket"
require "openssl"
require "log"
require "./client"
require "./channel_pool"

module AMQProxy
  class Upstream
    Log = ::Log.for(self)
    @socket : IO
    @unsafe_channels = Set(UInt16).new
    @channels = Hash(UInt16, DownstreamChannel?).new
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
          if @channels.has_key?(i)
            if @channels[i].nil?
              @channels[i] = downstream_channel
              return UpstreamChannel.new(self, i) # reuse
            else
              next # in use
            end
          else
            @channels[i] = downstream_channel
            send AMQ::Protocol::Frame::Channel::Open.new(i)
            return UpstreamChannel.new(self, i)
          end
        end
        raise ChannelMaxReached.new
      end
    end

    def unassign_channel(channel : UInt16)
      @channels_lock.synchronize do
        if @unsafe_channels.delete channel
          send AMQ::Protocol::Frame::Channel::Close.new(channel, 0u16, "", 0u16, 0u16)
          @channels.delete channel
        elsif @channels.has_key? channel
          @channels[channel] = nil # keep for reuse
        end
      end
    end

    def channels
      @channels.size
    end

    def active_channels
      @channels.count { |_, v| !v.nil? }
    end

    # Frames from upstream (to client)
    def read_loop(socket = @socket) # ameba:disable Metrics/CyclomaticComplexity
      Log.context.set(remote_address: @remote_address)
      loop do
        case frame = AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian)
        when AMQ::Protocol::Frame::Heartbeat then send frame
        when AMQ::Protocol::Frame::Connection::Close
          close_all_client_channels
          begin
            send AMQ::Protocol::Frame::Connection::CloseOk.new
          rescue WriteError
          end
          return
        when AMQ::Protocol::Frame::Connection::CloseOk then return
        when AMQ::Protocol::Frame::Connection::Blocked,
             AMQ::Protocol::Frame::Connection::Unblocked
          send_to_all_clients(frame)
        when AMQ::Protocol::Frame::Channel::OpenOk  # we assume it always succeeds
        when AMQ::Protocol::Frame::Channel::CloseOk # when channel pool requested channel close
        when AMQ::Protocol::Frame::Channel::Close
          send AMQ::Protocol::Frame::Channel::CloseOk.new(frame.channel)
          @unsafe_channels.delete(frame.channel)
          if downstream_channel = @channels.delete(frame.channel)
            downstream_channel.write(frame)
          end
        else
          if downstream_channel = @channels[frame.channel]?
            downstream_channel.write(frame)
          else
            Log.debug { "Frame for unmapped channel from upstream: #{frame}" }
            send AMQ::Protocol::Frame::Channel::Close.new(frame.channel, 500_u16,
              "DOWNSTREAM_DISCONNECTED", 0_u16, 0_u16)
          end
        end
      end
    rescue ex : IO::Error | OpenSSL::SSL::Error
      Log.error(exception: ex) { "Error reading from upstream" } unless socket.closed?
    ensure
      socket.close rescue nil
      close_all_client_channels
    end

    def closed?
      @socket.closed?
    end

    private def close_all_client_channels
      Log.debug { "Closing all client channels for closed upstream" }
      @channels_lock.synchronize do
        cnt = 0
        @channels.each_value do |downstream_channel|
          if dch = downstream_channel
            dch.close
            cnt += 1
          end
        end
        Log.debug { "Upstream connection closed, closing #{cnt} client channels" } unless cnt.zero?
        @channels.clear
      end
    end

    private def send_to_all_clients(frame : AMQ::Protocol::Frame::Connection)
      Log.debug { "Sending broadcast frame to all client connections" }
      clients = Set(Client).new
      @channels_lock.synchronize do
        @channels.each_value do |downstream_channel|
          if dc = downstream_channel
            clients << dc.client
          end
        end
      end
      clients.each do |client|
        client.write frame
      end
    end

    # Forward frames from client to upstream
    def write(frame : AMQ::Protocol::Frame) : Nil
      case frame
      when AMQ::Protocol::Frame::Basic::Publish,
           AMQ::Protocol::Frame::Basic::Qos
      when AMQ::Protocol::Frame::Basic::Get
        @unsafe_channels.add(frame.channel) unless frame.no_ack
      when AMQ::Protocol::Frame::Basic,
           AMQ::Protocol::Frame::Confirm,
           AMQ::Protocol::Frame::Tx
        @unsafe_channels.add(frame.channel)
      when AMQ::Protocol::Frame::Connection
        raise "Connection frames should not be sent through here: #{frame}"
      when AMQ::Protocol::Frame::Channel::CloseOk # when upstream server requested a channel close and client confirmed
        @channels_lock.synchronize do
          @unsafe_channels.delete(frame.channel)
          @channels.delete(frame.channel)
        end
      when AMQ::Protocol::Frame::Channel
        raise "Channel frames should not be sent through here: #{frame}"
      end
      send frame
    end

    private def send(frame : AMQ::Protocol::Frame) : Nil
      @lock.synchronize do
        @socket.write_bytes frame, IO::ByteFormat::NetworkEndian
        @socket.flush
      rescue ex : IO::Error | OpenSSL::SSL::Error
        @socket.close rescue nil
        raise WriteError.new "Error writing to upstream", ex
      end
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
        tune_ok = AMQ::Protocol::Frame::Connection::TuneOk.new(channel_max, 4096, tune.heartbeat)
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
