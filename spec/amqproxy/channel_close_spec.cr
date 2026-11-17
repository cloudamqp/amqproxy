require "../spec_helper"

# AMQP server that can close channel 1 on demand, and records frames that
# arrive on it after the proxy answered with Channel#CloseOk, which RabbitMQ
# would answer by closing the whole connection
class ChannelClosingUpstream
  getter port : Int32
  getter publishes = 0
  getter frames_after_close_ok = 0
  getter connection_closes = 0
  @sockets = Array(TCPSocket).new
  @closed_channels = Set(UInt16).new

  FRAME_MAX = 131_072_u32

  def initialize
    @tcp = TCPServer.new("127.0.0.1", 0)
    @port = @tcp.local_address.port
    spawn accept_loop, name: "ChannelClosingUpstream#accept_loop"
  end

  def close_channel(id : UInt16)
    @sockets.each do |socket|
      send socket, AMQ::Protocol::Frame::Channel::Close.new(id, 406_u16, "PRECONDITION_FAILED - closed by test", 0_u16, 0_u16)
    end
  end

  def close
    @tcp.close
    @sockets.each { |socket| socket.close rescue nil }
  end

  private def accept_loop
    while socket = @tcp.accept?
      @sockets << socket
      spawn handle(socket), name: "ChannelClosingUpstream#handle"
    end
  end

  private def handle(socket : TCPSocket)
    socket.sync = false
    stream = AMQ::Protocol::Stream.new(socket, FRAME_MAX)
    negotiate(socket, stream)
    loop do
      frame = stream.next_frame
      case frame
      when AMQ::Protocol::Frame::Channel::Open
        @closed_channels.delete(frame.channel)
        send socket, AMQ::Protocol::Frame::Channel::OpenOk.new(frame.channel)
      when AMQ::Protocol::Frame::Channel::CloseOk
        @closed_channels << frame.channel
      when AMQ::Protocol::Frame::Connection::Close
        @connection_closes += 1
        send socket, AMQ::Protocol::Frame::Connection::CloseOk.new
        break
      else
        if @closed_channels.includes?(frame.channel)
          @frames_after_close_ok += 1
        elsif frame.is_a?(AMQ::Protocol::Frame::Basic::Publish)
          @publishes += 1
        end
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

# AMQP server that can flood or close a channel on one of its connections,
# and counts Channel#Open frames for an id it's still waiting for the proxy's
# CloseOk on, which RabbitMQ would discard, leaving that channel unopened
class ChannelReuseUpstream
  getter port : Int32
  getter opens_while_closing = 0
  @sockets = Array(TCPSocket).new
  @awaiting_close_ok = Array(Set(UInt16)).new

  FRAME_MAX = 131_072_u32

  def initialize
    @tcp = TCPServer.new("127.0.0.1", 0)
    @port = @tcp.local_address.port
    spawn accept_loop, name: "ChannelReuseUpstream#accept_loop"
  end

  def connections
    @sockets.size
  end

  # Sends *count* body frames of 100 kB on *channel* of connection *index*
  def flood(index : Int32, channel : UInt16, count : Int32)
    socket = @sockets[index]
    body = Bytes.new(100_000)
    spawn(name: "ChannelReuseUpstream#flood") do
      count.times { send socket, AMQ::Protocol::Frame::BytesBody.new(channel, body.size.to_u32, body) }
    rescue IO::Error
    end
  end

  def close_channel(index : Int32, channel : UInt16)
    @awaiting_close_ok[index] << channel
    send @sockets[index], AMQ::Protocol::Frame::Channel::Close.new(channel, 406_u16, "PRECONDITION_FAILED - closed by test", 0_u16, 0_u16)
  end

  def close
    @tcp.close
    @sockets.each { |socket| socket.close rescue nil }
  end

  private def accept_loop
    while socket = @tcp.accept?
      @sockets << socket
      @awaiting_close_ok << Set(UInt16).new
      spawn handle(socket, @sockets.size - 1), name: "ChannelReuseUpstream#handle"
    end
  end

  private def handle(socket : TCPSocket, index : Int32)
    socket.sync = false
    stream = AMQ::Protocol::Stream.new(socket, FRAME_MAX)
    negotiate(socket, stream)
    loop do
      case frame = stream.next_frame
      when AMQ::Protocol::Frame::Channel::Open
        @opens_while_closing += 1 if @awaiting_close_ok[index].includes?(frame.channel)
        send socket, AMQ::Protocol::Frame::Channel::OpenOk.new(frame.channel)
      when AMQ::Protocol::Frame::Channel::CloseOk
        @awaiting_close_ok[index].delete(frame.channel)
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

# AMQP client that reads frames only when told to, so the test controls
# what it has seen when it sends something
class StepClient
  FRAME_MAX = 131_072_u32

  def initialize(url : String)
    uri = URI.parse(url)
    @socket = TCPSocket.new(uri.hostname || "127.0.0.1", uri.port || 5672)
    @socket.sync = false
    @socket.read_timeout = 5.seconds
    @stream = AMQ::Protocol::Stream.new(@socket, FRAME_MAX)
    negotiate
  end

  def open_channel(id : UInt16)
    send AMQ::Protocol::Frame::Channel::Open.new(id)
    next_frame.should be_a AMQ::Protocol::Frame::Channel::OpenOk
  end

  def publish(channel : UInt16)
    body = "hello".to_slice
    @socket.write_bytes AMQ::Protocol::Frame::Basic::Publish.new(channel, 0_u16, "", "q", false, false), IO::ByteFormat::NetworkEndian
    @socket.write_bytes AMQ::Protocol::Frame::Header.new(channel, 60_u16, 0_u16, body.size.to_u64, AMQ::Protocol::Properties.new), IO::ByteFormat::NetworkEndian
    send AMQ::Protocol::Frame::BytesBody.new(channel, body.size.to_u32, body)
  end

  def send(frame)
    @socket.write_bytes frame, IO::ByteFormat::NetworkEndian
    @socket.flush
  end

  def next_frame
    @stream.next_frame
  end

  def close
    @socket.close rescue nil
  end

  private def negotiate
    @socket.write AMQ::Protocol::PROTOCOL_START_0_9_1.to_slice
    @socket.flush
    @stream.next_frame.as(AMQ::Protocol::Frame::Connection::Start)
    send AMQ::Protocol::Frame::Connection::StartOk.new(client_properties: AMQ::Protocol::Table.new,
      mechanism: "PLAIN", response: "\u0000guest\u0000guest", locale: "en_US")
    @stream.next_frame.as(AMQ::Protocol::Frame::Connection::Tune)
    send AMQ::Protocol::Frame::Connection::TuneOk.new(UInt16::MAX, FRAME_MAX, 0_u16)
    send AMQ::Protocol::Frame::Connection::Open.new(vhost: "/")
    @stream.next_frame.as(AMQ::Protocol::Frame::Connection::OpenOk)
  end
end

describe AMQProxy::Client do
  it "discards frames on a channel the upstream closed until the client's CloseOk" do
    upstream = ChannelClosingUpstream.new
    begin
      with_proxy_to(upstream.port) do |proxy_url|
        client = StepClient.new(proxy_url)
        begin
          client.open_channel(1_u16)
          client.publish(1_u16)
          wait_until { upstream.publishes == 1 }.should be_true, "Publish never reached upstream"

          upstream.close_channel(1_u16)
          close = client.next_frame
          close.should be_a AMQ::Protocol::Frame::Channel::Close
          close.channel.should eq 1
          # frames the client had sent before it saw the Close
          3.times { client.publish(1_u16) }
          client.send AMQ::Protocol::Frame::Channel::CloseOk.new(1_u16)

          # the channel can be opened again on the same, still open, upstream
          client.open_channel(1_u16)
          client.publish(1_u16)
          wait_until { upstream.publishes == 2 }.should be_true, "Publish on reopened channel never reached upstream"
          upstream.frames_after_close_ok.should eq 0
          upstream.connection_closes.should eq 0
        ensure
          client.close
        end
      end
    ensure
      upstream.close
    end
  end

  it "closes the connection with CHANNEL_ERROR on a publish to a channel that isn't open" do
    upstream = ChannelClosingUpstream.new
    begin
      with_proxy_to(upstream.port) do |proxy_url|
        client = StepClient.new(proxy_url)
        begin
          client.publish(7_u16)
          close = client.next_frame
          close.should be_a AMQ::Protocol::Frame::Connection::Close
          close.as(AMQ::Protocol::Frame::Connection::Close).reply_code.should eq 504
        ensure
          client.close
        end
      end
    ensure
      upstream.close
    end
  end

  it "closes the connection with CHANNEL_ERROR on a publish to channel 0" do
    upstream = ChannelClosingUpstream.new
    begin
      with_proxy_to(upstream.port) do |proxy_url|
        client = StepClient.new(proxy_url)
        begin
          client.publish(0_u16)
          close = client.next_frame
          close.should be_a AMQ::Protocol::Frame::Connection::Close
          close.as(AMQ::Protocol::Frame::Connection::Close).reply_code.should eq 504
        ensure
          client.close
        end
      end
    ensure
      upstream.close
    end
  end

  it "doesn't reuse a channel id upstream before the server has the proxy's CloseOk" do
    upstream = ChannelReuseUpstream.new
    server = AMQProxy::Server.new("127.0.0.1", upstream.port, false, 5, 1_u16) # one channel per upstream
    tcp_server = TCPServer.new("127.0.0.1", 0)
    spawn { server.listen(tcp_server) }
    Fiber.yield
    proxy_url = "amqp://#{tcp_server.local_address}"
    slow = StepClient.new(proxy_url)
    clients = [slow]
    begin
      slow.open_channel(1_u16) # upstream connection 0, channel 1
      slow.open_channel(2_u16) # upstream connection 1, channel 1
      # the slow client never reads, so forwarding the flood blocks, holding
      # the lock for writes to that client
      upstream.flood(1, 1_u16, 400)
      sleep 0.5.seconds
      # forwarding this Close then waits for that lock
      upstream.close_channel(0, 1_u16)
      sleep 0.2.seconds
      other = StepClient.new(proxy_url)
      clients << other
      other.open_channel(1_u16)
      sleep 0.2.seconds
      upstream.opens_while_closing.should eq 0
    ensure
      clients.each &.close
      server.stop_accepting_clients
      upstream.close
    end
  end
end
