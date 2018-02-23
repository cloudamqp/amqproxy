require "socket"
require "openssl"
require "uri"

module AMQProxy
  class Upstream
    def initialize(@host : String, @port : Int32, @tls : Bool)
      @socket = uninitialized IO
      @outbox = Channel(AMQP::Frame?).new
      @open_channels = Set(UInt16).new
    end

    def connect(user : String, password : String, vhost : String)
      tcp_socket = TCPSocket.new(@host, @port)
      print "Connected to upstream ", tcp_socket.remote_address, "\n"
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
      puts "Upstream connection failed to #{user}@#{@host}:#{@port}/#{vhost}"
      ex.inspect_with_backtrace(STDERR)
      nil
    end

    private def decode_frames
      loop do
        frame = AMQP::Frame.decode @socket
        case frame
        when AMQP::Channel::OpenOk
          @open_channels.add(frame.channel)
        when AMQP::Channel::CloseOk
          @open_channels.delete(frame.channel)
        end
        @outbox.send frame
      end
    rescue ex : Errno | IO::EOFError
      print "proxy decode frame: ", ex.message, "\n"
      @outbox.send nil
    end

    def next_frame
      @outbox.receive_select_action
    end

    def write(bytes : Slice(UInt8))
      @socket.write bytes
    rescue ex : Errno | IO::EOFError
      puts "proxy write bytes: #{ex.message}"
      @outbox.send nil
    end

    def close
      @socket.close
    end

    def closed?
      @socket.closed?
    end

    def close_all_open_channels
      @open_channels.each do |ch|
        puts "Closing client channel #{ch}"
        write AMQP::Channel::Close.new(ch, 200_u16, "", 0_u16, 0_u16).to_slice
        #close_ok = AMQP::Frame.decode(@socket).as(AMQP::Channel::CloseOk)
      end
    end

    private def start(user, password, vhost)
      @socket.write AMQP::PROTOCOL_START

      start = AMQP::Frame.decode(@socket).as(AMQP::Connection::Start)

      props = {
        "product" => "AMQProxy",
        "version" => AMQProxy::VERSION,
        "capabilities" => {
          "authentication_failure_close" => true
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
