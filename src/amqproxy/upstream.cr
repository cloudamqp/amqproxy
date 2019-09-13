require "socket"
require "openssl"
require "uri"
require "./client"

module AMQProxy
  class Upstream
    getter close_channel
    setter current_client

    @current_client : Client?

    def initialize(@host : String, @port : Int32, @tls : Bool, @log : Logger)
      @socket = uninitialized IO
      @close_channel = Channel(Nil).new
      @open_channels = Set(UInt16).new
      @unsafe_channels = Set(UInt16).new
    end

    def connect(user : String, password : String, vhost : String)
      tcp_socket = TCPSocket.new(@host, @port)
      tcp_socket.keepalive = true
      tcp_socket.tcp_keepalive_idle = 60
      tcp_socket.tcp_keepalive_count = 3
      tcp_socket.tcp_keepalive_interval = 10
      @socket =
        if @tls
          OpenSSL::SSL::Socket::Client.new(tcp_socket, hostname: @host).tap do |c|
            c.sync_close = true
          end
        else
          tcp_socket
        end
      start(user, password, vhost)
      spawn decode_frames
      self
    end

    # Frames from upstream (to client)
    def decode_frames
      loop do
        AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) do |frame|
          case frame
          when AMQ::Protocol::Frame::Channel::OpenOk
            @open_channels.add(frame.channel)
          when AMQ::Protocol::Frame::Channel::CloseOk
            @open_channels.delete(frame.channel)
            @unsafe_channels.delete(frame.channel)
          when AMQ::Protocol::Frame::Connection::Close
            @log.error "Upstream closed connection: #{frame.reply_text}"
            write AMQ::Protocol::Frame::Connection::CloseOk.new
            return
          when AMQ::Protocol::Frame::Connection::CloseOk
            return
          end
          if @current_client
            @current_client.not_nil!.write(frame)
          elsif !frame.is_a? AMQ::Protocol::Frame::Channel::CloseOk
            @log.error "Receiving #{frame.inspect} but no client to delivery to"
          end
        end
      end
    rescue ex : Errno | IO::EOFError
      @log.error "Error reading from upstream: #{ex.inspect_with_backtrace}"
    ensure
      @socket.close
      @close_channel.send nil
    end

    SAFE_BASIC_METHODS = [40, 10]

    # Frames from client (to upstream)
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
      frame.to_io(@socket, IO::ByteFormat::NetworkEndian)
      @socket.flush
      nil
    rescue ex : Errno | IO::EOFError
      @log.error "Error sending to upstream: #{ex.inspect}"
      @socket.close
      @close_channel.send nil
      nil
    end

    def close(reason = "")
      close = AMQ::Protocol::Frame::Connection::Close.new(200_u16, reason, 0_u16, 0_u16)
      close.to_io(@socket, IO::ByteFormat::NetworkEndian)
      @socket.flush
    end

    def closed?
      @socket.closed?
    end

    def client_disconnected
      @open_channels.each do |ch|
        if @unsafe_channels.includes? ch
          close = AMQ::Protocol::Frame::Channel::Close.new(ch, 200_u16, "Client disconnected", 0_u16, 0_u16)
          close.to_io @socket, IO::ByteFormat::NetworkEndian
          @socket.flush
        end
      end
    end

    private def start(user, password, vhost)
      @socket.write AMQ::Protocol::PROTOCOL_START_0_9_1.to_slice
      @socket.flush

      start = AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) { |f| f.as(AMQ::Protocol::Frame::Connection::Start) }

      props = AMQ::Protocol::Table.new({
        "product" => "AMQProxy",
        "version" => AMQProxy::VERSION,
        "capabilities" => {
          "authentication_failure_close" => true,
          "consumer_cancel_notify" => false,
          "publisher_confirms" => true,
          "exchange_exchange_bindings" => true,
          "basic.nack" => true,
          "per_consumer_qos" => true,
          "connection.blocked" => true
        } of String => AMQ::Protocol::Field
      } of String => AMQ::Protocol::Field)
      start_ok = AMQ::Protocol::Frame::Connection::StartOk.new(response: "\u0000#{user}\u0000#{password}",
                                                               client_properties: props, mechanism: "PLAIN", locale: "en_US")
      start_ok.to_io @socket, IO::ByteFormat::NetworkEndian
      @socket.flush

      tune = AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) { |f| f.as(AMQ::Protocol::Frame::Connection::Tune) }
      tune_ok = AMQ::Protocol::Frame::Connection::TuneOk.new(tune.channel_max, tune.frame_max, 0_u16)
      tune_ok.to_io @socket, IO::ByteFormat::NetworkEndian
      @socket.flush

      open = AMQ::Protocol::Frame::Connection::Open.new(vhost: vhost)
      open.to_io @socket, IO::ByteFormat::NetworkEndian
      @socket.flush

      open_ok = AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) do |f|
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
  end
end
