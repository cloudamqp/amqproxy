require "../spec_helper"

# AMQP server that can close all its connections, like RabbitMQ does when a
# node is put into maintenance mode
class ClosingUpstream
  getter publishes = 0
  getter channel_closes = 0
  getter port : Int32
  @sockets = Array(TCPSocket).new

  FRAME_MAX = 131_072_u32

  def initialize
    @tcp = TCPServer.new("127.0.0.1", 0)
    @port = @tcp.local_address.port
    spawn accept_loop, name: "ClosingUpstream#accept_loop"
  end

  def close_connections
    @sockets.each do |socket|
      next if socket.closed?
      send socket, AMQ::Protocol::Frame::Connection::Close.new(320_u16,
        "CONNECTION_FORCED - Node was put into maintenance mode", 0_u16, 0_u16)
    end
  end

  def close
    @tcp.close
    @sockets.each &.close
  end

  private def accept_loop
    while socket = @tcp.accept?
      @sockets << socket
      spawn handle(socket), name: "ClosingUpstream#handle"
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
        @channel_closes += 1
        send socket, AMQ::Protocol::Frame::Channel::CloseOk.new(frame.channel)
      when AMQ::Protocol::Frame::Basic::Publish
        @publishes += 1
      when AMQ::Protocol::Frame::Connection::Close
        send socket, AMQ::Protocol::Frame::Connection::CloseOk.new
        break
      when AMQ::Protocol::Frame::Connection::CloseOk
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

# Raw AMQP client that publishes but never answers Connection#Close by itself,
# so it behaves like a publisher that never reads from its socket
class PublishOnlyClient
  getter connection_closes = 0
  getter? disconnected = false

  FRAME_MAX = 131_072_u32

  def initialize(url : String)
    uri = URI.parse(url)
    @socket = TCPSocket.new(uri.hostname || "127.0.0.1", uri.port || 5672)
    @socket.sync = false
    @stream = AMQ::Protocol::Stream.new(@socket, FRAME_MAX)
    negotiate
    send AMQ::Protocol::Frame::Channel::Open.new(1_u16)
    @stream.next_frame.as(AMQ::Protocol::Frame::Channel::OpenOk)
    spawn read_loop, name: "PublishOnlyClient#read_loop"
  end

  def publish
    body = "hello".to_slice
    @socket.write_bytes AMQ::Protocol::Frame::Basic::Publish.new(1_u16, 0_u16, "", "q", false, false), IO::ByteFormat::NetworkEndian
    @socket.write_bytes AMQ::Protocol::Frame::Header.new(1_u16, 60_u16, 0_u16, body.size.to_u64, AMQ::Protocol::Properties.new), IO::ByteFormat::NetworkEndian
    send AMQ::Protocol::Frame::BytesBody.new(1_u16, body.size.to_u32, body)
  end

  def send(frame)
    @socket.write_bytes frame, IO::ByteFormat::NetworkEndian
    @socket.flush
  end

  def close
    @socket.close rescue nil
  end

  private def read_loop
    loop do
      @connection_closes += 1 if @stream.next_frame.is_a?(AMQ::Protocol::Frame::Connection::Close)
    end
  rescue IO::Error | AMQ::Protocol::Error
    @disconnected = true
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
  it "closes a client that doesn't answer Connection#Close after upstream closed" do
    upstream = ClosingUpstream.new
    begin
      with_proxy_to(upstream.port, client_close_timeout: 500.milliseconds) do |proxy_url|
        client = PublishOnlyClient.new(proxy_url)
        begin
          client.publish
          wait_until { upstream.publishes == 1 }.should be_true, "Publish never reached upstream"
          upstream.close_connections
          spawn do
            until client.disconnected?
              client.publish
              sleep 100.milliseconds
            end
          rescue IO::Error
          end
          wait_until { client.disconnected? }.should be_true, "Proxy didn't close the client connection"
          client.connection_closes.should eq 1
        ensure
          client.close
        end
      end
    ensure
      upstream.close
    end
  end

  it "doesn't forward frames from a client after sending it Connection#Close" do
    upstream = ClosingUpstream.new
    begin
      with_proxy_to(upstream.port) do |proxy_url|
        client = PublishOnlyClient.new(proxy_url)
        begin
          client.publish
          wait_until { upstream.publishes == 1 }.should be_true, "Publish never reached upstream"
          # channel 2 was never opened, so the proxy answers with Connection#Close
          client.send AMQ::Protocol::Frame::Channel::Close.new(2_u16, 200_u16, "", 0_u16, 0_u16)
          wait_until { client.connection_closes == 1 }.should be_true, "Proxy didn't send Connection#Close"
          client.publish
          client.send AMQ::Protocol::Frame::Connection::CloseOk.new
          # the proxy closes the upstream channel after the CloseOk, on the same
          # socket as a forwarded publish would have been sent
          wait_until { upstream.channel_closes == 1 }.should be_true, "Proxy didn't close the upstream channel"
          upstream.publishes.should eq 1
          wait_until { client.disconnected? }.should be_true, "Proxy didn't close the client connection"
        ensure
          client.close
        end
      end
    ensure
      upstream.close
    end
  end
end
