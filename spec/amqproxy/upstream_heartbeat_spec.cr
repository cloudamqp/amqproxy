require "../spec_helper"

# AMQP server that counts received heartbeats but never sends any itself,
# like RabbitMQ does while it's busy sending to a consumer
class HeartbeatCountingServer
  getter heartbeats = 0
  getter port : Int32
  @sockets = Array(TCPSocket).new

  FRAME_MAX = 131_072_u32

  def initialize(@heartbeat : UInt16)
    @tcp = TCPServer.new("127.0.0.1", 0)
    @port = @tcp.local_address.port
    spawn accept_loop, name: "HeartbeatCountingServer#accept_loop"
  end

  def close
    @tcp.close
    @sockets.each &.close
  end

  private def accept_loop
    while socket = @tcp.accept?
      @sockets << socket
      spawn handle(socket), name: "HeartbeatCountingServer#handle"
    end
  end

  private def handle(socket : TCPSocket)
    socket.sync = false
    stream = AMQ::Protocol::Stream.new(socket, FRAME_MAX)
    negotiate(socket, stream)
    loop do
      case frame = stream.next_frame
      when AMQ::Protocol::Frame::Heartbeat
        @heartbeats += 1
      when AMQ::Protocol::Frame::Channel::Open
        send socket, AMQ::Protocol::Frame::Channel::OpenOk.new(frame.channel)
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
    send socket, AMQ::Protocol::Frame::Connection::Tune.new(UInt16::MAX, FRAME_MAX, @heartbeat)
    stream.next_frame.as(AMQ::Protocol::Frame::Connection::TuneOk)
    stream.next_frame.as(AMQ::Protocol::Frame::Connection::Open)
    send socket, AMQ::Protocol::Frame::Connection::OpenOk.new
  end

  private def send(socket, frame)
    socket.write_bytes frame, IO::ByteFormat::NetworkEndian
    socket.flush
  end
end

def with_proxy_to(upstream_port, &)
  server = AMQProxy::Server.new("127.0.0.1", upstream_port, false)
  tcp_server = TCPServer.new("127.0.0.1", 0)
  spawn { server.listen(tcp_server) }
  Fiber.yield
  yield "amqp://#{tcp_server.local_address}"
ensure
  if s = server
    s.stop_accepting_clients
  end
end

describe AMQProxy::Upstream do
  it "sends heartbeats to upstream when the connection is idle" do
    upstream = HeartbeatCountingServer.new(2_u16)
    begin
      with_proxy_to(upstream.port) do |proxy_url|
        AMQP::Client.start(proxy_url) do |conn|
          conn.channel
          wait_until { upstream.heartbeats >= 2 }.should be_true, "No heartbeats sent to upstream (got #{upstream.heartbeats})"
        end
      end
    ensure
      upstream.close
    end
  end

  it "doesn't send heartbeats when upstream negotiated them off" do
    upstream = HeartbeatCountingServer.new(0_u16)
    begin
      with_proxy_to(upstream.port) do |proxy_url|
        AMQP::Client.start(proxy_url) do |conn|
          conn.channel
          sleep 2.seconds
          upstream.heartbeats.should eq 0
        end
      end
    ensure
      upstream.close
    end
  end
end
