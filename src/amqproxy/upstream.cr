require "socket"
require "openssl"
require "uri"

module AMQProxy
  class Upstream
    def initialize(@host : String, @port : Int32, @tls : Bool, @log : Logger)
      @socket = uninitialized IO
      @to_client = Channel(AMQP::Frame?).new(1)
      @open_channels = Set(UInt16).new
      @unsafe_channels = Set(UInt16).new
    end

    def connect(user : String, password : String, vhost : String)
      tcp_socket = TCPSocket.new(@host, @port)
      tcp_socket.tcp_nodelay = true
      @log.info { "Connected to upstream #{tcp_socket.remote_address}" }
      @socket =
        if @tls
          OpenSSL::SSL::Socket::Client.new(tcp_socket, hostname: @host).tap do |c|
            c.sync_close = c.sync = true
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
    private def decode_frames
      loop do
        frame = AMQP::Frame.decode @socket
        case frame
        when AMQP::Channel::OpenOk
          @open_channels.add(frame.channel)
        when AMQP::Channel::CloseOk
          @open_channels.delete(frame.channel)
          @unsafe_channels.delete(frame.channel)
        end
        @to_client.send frame
      end
    rescue ex : Errno | IO::EOFError
      @log.error "Error reading from upstream: #{ex.inspect}"
      @to_client.send nil
    end

    def next_frame
      @to_client.receive_select_action
    end

    SAFE_BASIC_METHODS = [40, 10]

    # Frames from client (to upstream)
    def write(frame : AMQP::Frame)
      case frame
      when AMQP::Basic::Get
        unless frame.no_ack
          @unsafe_channels.add(frame.channel)
        end
      when AMQP::Basic
        unless SAFE_BASIC_METHODS.includes? frame.method_id
          @unsafe_channels.add(frame.channel)
        end
      when AMQP::Connection::Close
        @to_client.send AMQP::Connection::CloseOk.new
        return
      when AMQP::Channel::Open
        if @open_channels.includes? frame.channel
          @to_client.send AMQP::Channel::OpenOk.new(frame.channel)
          return
        end
      when AMQP::Channel::Close
        unless @unsafe_channels.includes? frame.channel
          @to_client.send AMQP::Channel::CloseOk.new(frame.channel)
          return
        end
      end
      @socket.write frame.to_slice
    rescue ex : Errno | IO::EOFError
      @log.error "Error sending to upstream: #{ex.inspect}"
      @to_client.send nil
      close
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
          @socket.write AMQP::Channel::Close.new(ch, 200_u16, "", 0_u16, 0_u16).to_slice
          close_ok = AMQP::Frame.decode(@socket).as(AMQP::Channel::CloseOk)
          @open_channels.delete(ch)
          @unsafe_channels.delete(ch)
        end
      end
    end

    private def start(user, password, vhost)
      @socket.write AMQP::PROTOCOL_START

      start = AMQP::Frame.decode(@socket).as(AMQP::Connection::Start)

      props = {
        "product" => "AMQProxy",
        "version" => AMQProxy::VERSION,
        "capabilities" => {
          "authentication_failure_close" => false
        } of String => AMQP::Field
      } of String => AMQP::Field
      start_ok = AMQP::Connection::StartOk.new(response: "\u0000#{user}\u0000#{password}",
                                               client_props: props)
      @socket.write start_ok.to_slice

      tune = AMQP::Frame.decode(@socket).as(AMQP::Connection::Tune)
      tune_ok = AMQP::Connection::TuneOk.new(tune.channel_max, tune.frame_max, 0_u16)
      @socket.write tune_ok.to_slice

      open = AMQP::Connection::Open.new(vhost: vhost)
      @socket.write open.to_slice

      open_ok = AMQP::Frame.decode(@socket).as(AMQP::Connection::OpenOk)
    end
  end
end
