require "../spec_helper"

# AMQP server that serves its first `serve` connections and accepts the rest
# without ever sending Connection#Start, like a broker that is stuck starting
class StallingUpstream
  getter port : Int32
  getter accepted = 0
  @sockets = Array(TCPSocket).new

  FRAME_MAX = 131_072_u32

  def initialize(@serve : Int32)
    @tcp = TCPServer.new("127.0.0.1", 0)
    @port = @tcp.local_address.port
    spawn accept_loop, name: "StallingUpstream#accept_loop"
  end

  def close
    @tcp.close
    @sockets.each { |socket| socket.close rescue nil }
  end

  private def accept_loop
    while socket = @tcp.accept?
      @accepted += 1
      @sockets << socket
      spawn handle(socket), name: "StallingUpstream#handle" if @accepted <= @serve
    end
  end

  private def handle(socket : TCPSocket)
    socket.sync = false
    stream = AMQ::Protocol::Stream.new(socket, FRAME_MAX)
    negotiate(socket, stream)
    loop do
      case frame = stream.next_frame
      when AMQ::Protocol::Frame::Channel::Open
        send socket, AMQ::Protocol::Frame::Channel::OpenOk.new(frame.channel)
      when AMQ::Protocol::Frame::Channel::Close
        send socket, AMQ::Protocol::Frame::Channel::CloseOk.new(frame.channel)
      when AMQ::Protocol::Frame::Connection::Close
        send socket, AMQ::Protocol::Frame::Connection::CloseOk.new
        break
      end
    end
  rescue IO::Error
  ensure
    socket.close rescue nil
  end

  private def negotiate(socket, stream)
    proto = uninitialized UInt8[8]
    socket.read_fully(proto.to_slice)
    send socket, AMQ::Protocol::Frame::Connection::Start.new
    stream.next_frame.as(AMQ::Protocol::Frame::Connection::StartOk)
    send socket, AMQ::Protocol::Frame::Connection::Tune.new(UInt16::MAX, FRAME_MAX, 0_u16)
    stream.next_frame.as(AMQ::Protocol::Frame::Connection::TuneOk)
    stream.next_frame.as(AMQ::Protocol::Frame::Connection::Open)
    send socket, AMQ::Protocol::Frame::Connection::OpenOk.new
  end

  private def send(socket, frame)
    socket.write_bytes frame, IO::ByteFormat::NetworkEndian
    socket.flush
  end
end

private def with_proxy(upstream_port, connect_timeout, max_upstream_channels = UInt16::MAX, &)
  server = AMQProxy::Server.new("127.0.0.1", upstream_port, false, 5, max_upstream_channels,
    upstream_connect_timeout: connect_timeout)
  tcp_server = TCPServer.new("127.0.0.1", 0)
  spawn { server.listen(tcp_server) }
  Fiber.yield
  yield "amqp://#{tcp_server.local_address}"
ensure
  server.try &.stop_accepting_clients
end

# Opens a channel and returns the error, or nil if it opened
private def open_channel_error(conn) : Exception?
  conn.channel
  nil
rescue ex
  ex
end

describe AMQProxy::ChannelPool do
  it "fails Channel#Open when the upstream never completes the handshake" do
    upstream = StallingUpstream.new(serve: 0)
    begin
      with_proxy(upstream.port, 300.milliseconds) do |proxy_url|
        conn = AMQP::Client.new(proxy_url).connect
        begin
          elapsed = Time.measure do
            open_channel_error(conn).should_not be_nil
          end
          elapsed.should be < 2.seconds
        ensure
          conn.close rescue nil
        end
      end
    ensure
      upstream.close
    end
  end

  it "opens channels on a connected upstream while another upstream is being dialed" do
    upstream = StallingUpstream.new(serve: 1)
    begin
      # one channel per upstream, so the second channel needs a second upstream
      with_proxy(upstream.port, 5.seconds, max_upstream_channels: 1_u16) do |proxy_url|
        conn_a = AMQP::Client.new(proxy_url).connect
        conn_b = AMQP::Client.new(proxy_url).connect
        conn_c = AMQP::Client.new(proxy_url).connect
        begin
          ch_a = conn_a.channel
          spawn { open_channel_error(conn_b) } # dials the stalling second upstream
          wait_until { upstream.accepted == 2 }.should be_true, "Proxy never dialed a second upstream"
          ch_a.close # frees the only channel on the connected upstream
          elapsed = Time.measure do
            open_channel_error(conn_c).should be_nil
          end
          elapsed.should be < 1.second
        ensure
          conn_a.close rescue nil
          conn_b.close rescue nil
          conn_c.close rescue nil
        end
      end
    ensure
      upstream.close
    end
  end

  it "shares one upstream connection attempt between clients" do
    upstream = StallingUpstream.new(serve: 0)
    begin
      with_proxy(upstream.port, 1.second) do |proxy_url|
        conns = Array.new(3) { AMQP::Client.new(proxy_url).connect }
        begin
          errors = Channel(Exception?).new
          elapsed = Time.measure do
            conns.each { |conn| spawn { errors.send open_channel_error(conn) } }
            3.times { errors.receive.should_not be_nil }
          end
          upstream.accepted.should eq 1
          elapsed.should be < 1.8.seconds # not one timeout after the other
        ensure
          conns.each { |conn| conn.close rescue nil }
        end
      end
    ensure
      upstream.close
    end
  end
end
