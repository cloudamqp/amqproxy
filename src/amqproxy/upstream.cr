require "socket"
require "openssl"
require "./client"

module AMQProxy
  class Upstream
    property last_used = Time.monotonic
    setter current_client : Client?
    @socket : IO
    @open_channels = Set(UInt16).new
    @unsafe_channels = Set(UInt16).new
    @lock = Mutex.new

    def initialize(@host : String, @port : Int32, @tls_ctx : OpenSSL::SSL::Context::Client?, @log : Logger)
      tcp_socket = TCPSocket.new(@host, @port)
      tcp_socket.sync = false
      tcp_socket.keepalive = true
      tcp_socket.tcp_keepalive_idle = 60
      tcp_socket.tcp_keepalive_count = 3
      tcp_socket.tcp_keepalive_interval = 10
      tcp_socket.tcp_nodelay = true
      @socket =
        if tls_ctx = @tls_ctx
          OpenSSL::SSL::Socket::Client.new(tcp_socket, tls_ctx, hostname: @host).tap do |c|
            c.sync_close = true
          end
        else
          tcp_socket
        end
    end

    def connect(user : String, password : String, vhost : String)
      start(user, password, vhost)
      spawn read_loop, name: "upstream read loop #{@host}:#{@port}"
      self
    rescue ex : IO::Error | OpenSSL::SSL::Error
      raise Error.new "Cannot establish connection to upstream", ex
    end

    # Frames from upstream (to client)
    def read_loop # ameba:disable Metrics/CyclomaticComplexity
      socket = @socket
      loop do
        AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian) do |frame|
          case frame
          when AMQ::Protocol::Frame::Channel::OpenOk
            @open_channels.add(frame.channel)
          when AMQ::Protocol::Frame::Channel::Close,
               AMQ::Protocol::Frame::Channel::CloseOk
            @open_channels.delete(frame.channel)
            @unsafe_channels.delete(frame.channel)
          when AMQ::Protocol::Frame::Connection::CloseOk
            return
          when AMQ::Protocol::Frame::Heartbeat
            write frame
            next
          end
          if client = @current_client
            begin
              client.write(frame)
            rescue ex
              @log.error "#{frame.inspect} could not be sent to client: #{ex.inspect}"
              client.close_socket # close the socket of the client so that the client's read_loop exits
              client_disconnected
            end
          elsif !frame.is_a? AMQ::Protocol::Frame::Channel::CloseOk
            @log.error "Receiving #{frame.inspect} but no client to delivery to"
            if body = frame.as? AMQ::Protocol::Frame::Body
              body.body.skip(body.body_size)
            end
          end
          if frame.is_a? AMQ::Protocol::Frame::Connection::Close
            @log.error "Upstream closed connection: #{frame.reply_text}"
            begin
              write AMQ::Protocol::Frame::Connection::CloseOk.new
            rescue ex : WriteError
              @log.error "Error writing CloseOk to upstream: #{ex.inspect}"
            end
            return
          end
        end
      end
    rescue ex : IO::Error | OpenSSL::SSL::Error
      @log.error "Error reading from upstream: #{ex.inspect_with_backtrace}" unless @socket.closed?
    ensure
      @socket.close unless @socket.closed?
    end

    SAFE_BASIC_METHODS = {40, 10} # qos and publish

    # Send frames to upstream (often from the client)
    def write(frame : AMQ::Protocol::Frame)
      case frame
      when AMQ::Protocol::Frame::Basic::Get
        unless frame.no_ack
          @unsafe_channels.add(frame.channel)
        end
      when AMQ::Protocol::Frame::Basic
        unless SAFE_BASIC_METHODS.includes? frame.method_id
          @unsafe_channels.add(frame.channel)
        end
      when AMQ::Protocol::Frame::Confirm
        @unsafe_channels.add(frame.channel)
      when AMQ::Protocol::Frame::Tx
        @unsafe_channels.add(frame.channel)
      when AMQ::Protocol::Frame::Connection::Close
        return AMQ::Protocol::Frame::Connection::CloseOk.new
      when AMQ::Protocol::Frame::Channel::Open
        if @open_channels.includes? frame.channel
          return AMQ::Protocol::Frame::Channel::OpenOk.new(frame.channel)
        end
      when AMQ::Protocol::Frame::Channel::Close
        unless @unsafe_channels.includes? frame.channel
          return AMQ::Protocol::Frame::Channel::CloseOk.new(frame.channel)
        end
      end
      @lock.synchronize do
        @socket.write_bytes frame, IO::ByteFormat::NetworkEndian
        @socket.flush
        nil
      rescue ex : IO::Error | OpenSSL::SSL::Error
        @socket.close
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

    def client_disconnected
      @current_client = nil
      return if closed?
      @lock.synchronize do
        @open_channels.each do |ch|
          if @unsafe_channels.includes? ch
            close = AMQ::Protocol::Frame::Channel::Close.new(ch, 200_u16, "Client disconnected", 0_u16, 0_u16)
            close.to_io @socket, IO::ByteFormat::NetworkEndian
            @socket.flush
          end
        end
      end
    end

    private def start(user, password, vhost)
      @socket.write AMQ::Protocol::PROTOCOL_START_0_9_1.to_slice
      @socket.flush

      # assert correct frame type
      AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) { |f| f.as(AMQ::Protocol::Frame::Connection::Start) }

      props = AMQ::Protocol::Table.new({
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
      start_ok = AMQ::Protocol::Frame::Connection::StartOk.new(response: "\u0000#{user}\u0000#{password}",
        client_properties: props, mechanism: "PLAIN", locale: "en_US")
      start_ok.to_io @socket, IO::ByteFormat::NetworkEndian
      @socket.flush

      tune = AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) { |f| f.as(AMQ::Protocol::Frame::Connection::Tune) }
      tune_ok = AMQ::Protocol::Frame::Connection::TuneOk.new(tune.channel_max, tune.frame_max, tune.heartbeat)
      tune_ok.to_io @socket, IO::ByteFormat::NetworkEndian
      @socket.flush

      open = AMQ::Protocol::Frame::Connection::Open.new(vhost: vhost)
      open.to_io @socket, IO::ByteFormat::NetworkEndian
      @socket.flush

      AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) do |f|
        case f
        when AMQ::Protocol::Frame::Connection::Close
          close_ok = AMQ::Protocol::Frame::Connection::CloseOk.new
          close_ok.to_io @socket, IO::ByteFormat::NetworkEndian
          @socket.flush
          @socket.close
          raise AccessError.new f.reply_text
        when AMQ::Protocol::Frame::Connection::OpenOk
          true
        end
      end
    rescue ex : AccessError
      raise ex
    rescue ex
      @socket.close
      raise Error.new ex.message, cause: ex
    end

    class Error < Exception; end

    class AccessError < Error; end

    class WriteError < Error; end
  end
end
