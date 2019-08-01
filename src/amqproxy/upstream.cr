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
      tcp_socket.sync = false
      tcp_socket.linger = 0
      tcp_socket.keepalive = true
      tcp_socket.tcp_nodelay = true
      tcp_socket.tcp_keepalive_idle = 60
      tcp_socket.tcp_keepalive_count = 3
      tcp_socket.tcp_keepalive_interval = 10
      @log.info { "Connected to upstream #{tcp_socket.remote_address}" }
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
    rescue ex : IO::EOFError
      @log.error "Failed connecting to upstream #{user}@#{@host}:#{@port}/#{vhost}"
      nil
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
          end
          @current_client.try &.write(frame)
        end
      end
    rescue ex : Errno | IO::EOFError
      @log.error "Error reading from upstream: #{ex.inspect}"
      close
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
      close
      @close_channel.send nil
      nil
    end

    def close
      @socket.close
    end

    def closed?
      @socket.closed?
    end

    def client_disconnected
      @open_channels.each do |ch|
        if @unsafe_channels.includes? ch
          close = AMQ::Protocol::Frame::Channel::Close.new(ch, 200_u16, "", 0_u16, 0_u16)
          close.to_io @socket, IO::ByteFormat::NetworkEndian
          @socket.flush
          AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) do |frame|
            case frame
            when AMQ::Protocol::Frame::Channel::CloseOk
              @open_channels.delete(ch)
              @unsafe_channels.delete(ch)
            else
              @log.error "When closing channel, got #{frame.class}, closing"
              @socket.close
            end
          end
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
          "authentication_failure_close" => false
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

      open_ok = AMQ::Protocol::Frame.from_io(@socket, IO::ByteFormat::NetworkEndian) { |f| f.as(AMQ::Protocol::Frame::Connection::OpenOk) }
    end
  end
end
