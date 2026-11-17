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

# AMQP server for the ways an upstream can misbehave during and after the
# handshake
class MisbehavingUpstream
  getter port : Int32
  getter accepted = 0
  # Delay before each handshake frame the server sends
  property handshake_step_delay = Time::Span.zero
  # Answer Connection#StartOk with this frame instead of Connection#Tune
  property tune_replacement : AMQ::Protocol::Frame? = nil
  property channel_max = UInt16::MAX
  # The first connection stops reading at its first Basic#Publish, like
  # RabbitMQ does with a publishing connection during a resource alarm
  property? first_stops_reading_on_publish = false
  @sockets = Array(TCPSocket).new
  @resume_reading = Channel(Nil).new

  FRAME_MAX = 131_072_u32

  def initialize
    @tcp = TCPServer.new("127.0.0.1", 0)
    @port = @tcp.local_address.port
    spawn accept_loop, name: "MisbehavingUpstream#accept_loop"
  end

  def resume_reading
    @resume_reading.close
  end

  def close
    resume_reading
    @tcp.close
    @sockets.each { |socket| socket.close rescue nil }
  end

  private def accept_loop
    while socket = @tcp.accept?
      @accepted += 1
      @sockets << socket
      spawn handle(socket, first: @accepted == 1), name: "MisbehavingUpstream#handle"
    end
  end

  private def handle(socket : TCPSocket, first : Bool)
    socket.sync = false
    stream = AMQ::Protocol::Stream.new(socket, FRAME_MAX)
    return unless negotiate(socket, stream)
    loop do
      case frame = stream.next_frame
      when AMQ::Protocol::Frame::Channel::Open
        send socket, AMQ::Protocol::Frame::Channel::OpenOk.new(frame.channel)
      when AMQ::Protocol::Frame::Basic::Publish
        @resume_reading.receive? if first && @first_stops_reading_on_publish
      when AMQ::Protocol::Frame::Connection::Close
        send socket, AMQ::Protocol::Frame::Connection::CloseOk.new
        break
      end
    end
  rescue IO::Error | AMQ::Protocol::Error
  ensure
    socket.close rescue nil
  end

  private def negotiate(socket, stream) : Bool
    proto = uninitialized UInt8[8]
    socket.read_fully(proto.to_slice)
    sleep @handshake_step_delay
    send socket, AMQ::Protocol::Frame::Connection::Start.new
    stream.next_frame.as(AMQ::Protocol::Frame::Connection::StartOk)
    sleep @handshake_step_delay
    if frame = @tune_replacement
      send socket, frame
      return false
    end
    send socket, AMQ::Protocol::Frame::Connection::Tune.new(@channel_max, FRAME_MAX, 0_u16)
    stream.next_frame.as(AMQ::Protocol::Frame::Connection::TuneOk)
    stream.next_frame.as(AMQ::Protocol::Frame::Connection::Open)
    sleep @handshake_step_delay
    send socket, AMQ::Protocol::Frame::Connection::OpenOk.new
    true
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

# Connects and returns the error, or nil if it connected
private def connect_error(url) : Exception?
  AMQP::Client.new(url).connect.close
  nil
rescue ex
  ex
end

describe AMQProxy::ChannelPool do
  it "fails the client's connect when the upstream never completes the handshake" do
    upstream = StallingUpstream.new(serve: 0)
    begin
      with_proxy(upstream.port, 300.milliseconds) do |proxy_url|
        error = nil
        elapsed = Time.measure do
          error = connect_error(proxy_url)
        end
        error.to_s.should contain "UPSTREAM_ERROR"
        elapsed.should be < 2.seconds
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

  it "shares one upstream connection attempt between connecting clients" do
    upstream = StallingUpstream.new(serve: 0)
    begin
      with_proxy(upstream.port, 1.second) do |proxy_url|
        errors = Channel(Exception?).new
        elapsed = Time.measure do
          3.times { spawn { errors.send connect_error(proxy_url) } }
          3.times { errors.receive.to_s.should contain "UPSTREAM_ERROR" }
        end
        upstream.accepted.should eq 1
        elapsed.should be < 1.8.seconds # not one timeout after the other
      end
    ensure
      upstream.close
    end
  end

  it "times out a handshake that takes too long in total, however fast each step is" do
    upstream = MisbehavingUpstream.new
    upstream.handshake_step_delay = 0.4.seconds # 1.2s in total, each step within the timeout
    begin
      with_proxy(upstream.port, 0.6.seconds) do |proxy_url|
        error = nil
        elapsed = Time.measure do
          error = connect_error(proxy_url)
        end
        error.to_s.should contain "Timeout after 0.6s"
        elapsed.should be < 1.second
      end
    ensure
      upstream.close
    end
  end

  it "opens channels on other upstreams while a write to one upstream blocks" do
    upstream = MisbehavingUpstream.new
    upstream.first_stops_reading_on_publish = true
    upstream.channel_max = 2_u16
    begin
      with_proxy(upstream.port, 5.seconds) do |proxy_url|
        publisher = AMQP::Client.new(proxy_url).connect
        blocked = AMQP::Client.new(proxy_url).connect
        other = AMQP::Client.new(proxy_url).connect
        begin
          channel = publisher.channel
          spawn do
            body = Bytes.new(1024 * 1024)
            64.times { channel.basic_publish(body, "", "q") } # more than the socket buffers hold
          rescue IO::Error | AMQP::Client::Error
          end
          sleep 0.5.seconds # until the proxy's writes to the first upstream block
          # takes the first upstream's last channel, and blocks writing Channel#Open
          spawn { open_channel_error(blocked) }
          sleep 0.2.seconds
          opened = Channel(Exception?).new(1)
          spawn { opened.send open_channel_error(other) }
          select
          when error = opened.receive
            error.should be_nil
          when timeout(2.seconds)
            fail "Channel#Open waited for a blocked write to another client's upstream"
          end
          upstream.accepted.should eq 2
        ensure
          # the clients' Connection#Close waits behind the blocked writes
          upstream.resume_reading
          publisher.close rescue nil
          blocked.close rescue nil
          other.close rescue nil
        end
      end
    ensure
      upstream.close
    end
  end

  it "sends the client a Connection#Close for an upstream error longer than a short string" do
    upstream = MisbehavingUpstream.new
    # answering StartOk with another Start fails the handshake with an error
    # that includes the frame, server properties and all
    upstream.tune_replacement = AMQ::Protocol::Frame::Connection::Start.new(
      server_properties: AMQ::Protocol::Table.new({product: "x" * 300}))
    begin
      with_proxy(upstream.port, 5.seconds) do |proxy_url|
        connect_error(proxy_url).to_s.should contain "UPSTREAM_ERROR"
      end
    ensure
      upstream.close
    end
  end

  it "closes a client that waits for an upstream connection when shutting down" do
    upstream = StallingUpstream.new(serve: 0)
    begin
      server = AMQProxy::Server.new("127.0.0.1", upstream.port, false, upstream_connect_timeout: 2.seconds)
      tcp_server = TCPServer.new("127.0.0.1", 0)
      spawn { server.listen(tcp_server) }
      Fiber.yield
      errors = Channel(Exception?).new(1)
      spawn { errors.send connect_error("amqp://#{tcp_server.local_address}") }
      wait_until { upstream.accepted == 1 }.should be_true, "Proxy never connected upstream"
      server.client_connections.should eq 1 # counted while it waits
      server.stop_accepting_clients
      server.disconnect_clients
      select
      when error = errors.receive
        error.to_s.should contain "AMQProxy shutdown"
      when timeout(1.second)
        fail "Client wasn't sent Connection#Close"
      end
      # gone once the connection attempt ends, instead of joining the
      # clients that a shutdown already disconnected
      wait_until(3.seconds) { server.client_connections.zero? }.should be_true
    ensure
      upstream.close
    end
  end
end
