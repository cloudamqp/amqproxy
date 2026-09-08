require "../spec_helper"

# Raw AMQP client, so that we control exactly when frames are sent to the proxy
# and can count the heartbeats it sends back. It never opens a channel, so no
# upstream connection is established.
class HeartbeatCountingClient
  getter heartbeats = 0
  getter? disconnected = false

  FRAME_MAX = 131_072_u32

  def initialize(url : String, heartbeat : UInt16)
    uri = URI.parse(url)
    @socket = TCPSocket.new(uri.hostname || "127.0.0.1", uri.port || 5672)
    @socket.sync = false
    @stream = AMQ::Protocol::Stream.new(@socket, FRAME_MAX)
    negotiate(heartbeat)
    spawn read_loop, name: "HeartbeatCountingClient#read_loop"
  end

  def send_heartbeat
    send AMQ::Protocol::Frame::Heartbeat.new
  end

  def close
    @socket.close rescue nil
  end

  private def read_loop
    loop do
      @heartbeats += 1 if @stream.next_frame.is_a?(AMQ::Protocol::Frame::Heartbeat)
    end
  rescue IO::Error | AMQ::Protocol::Error
    @disconnected = true
  end

  private def negotiate(heartbeat)
    @socket.write AMQ::Protocol::PROTOCOL_START_0_9_1.to_slice
    @socket.flush
    @stream.next_frame.as(AMQ::Protocol::Frame::Connection::Start)
    send AMQ::Protocol::Frame::Connection::StartOk.new(client_properties: AMQ::Protocol::Table.new,
      mechanism: "PLAIN", response: "\u0000guest\u0000guest", locale: "en_US")
    @stream.next_frame.as(AMQ::Protocol::Frame::Connection::Tune)
    send AMQ::Protocol::Frame::Connection::TuneOk.new(UInt16::MAX, FRAME_MAX, heartbeat)
    send AMQ::Protocol::Frame::Connection::Open.new(vhost: "/")
    @stream.next_frame.as(AMQ::Protocol::Frame::Connection::OpenOk)
  end

  private def send(frame)
    @socket.write_bytes frame, IO::ByteFormat::NetworkEndian
    @socket.flush
  end
end

describe AMQProxy::Client do
  it "sends heartbeats to a client that keeps sending frames itself" do
    with_server do |_server, amqp_url|
      client = HeartbeatCountingClient.new(amqp_url, 2_u16)
      begin
        # frames arrive just often enough to keep resetting a read based timer,
        # the heartbeats we owe the client must be sent regardless
        5.times do
          client.send_heartbeat
          sleep 900.milliseconds
        end
        client.heartbeats.should be >= 2, "Proxy sent #{client.heartbeats} heartbeats in 4.5s, expected one per second"
      ensure
        client.close
      end
    end
  end

  it "doesn't send heartbeats when the client negotiated them off" do
    with_server do |_server, amqp_url|
      client = HeartbeatCountingClient.new(amqp_url, 0_u16)
      begin
        sleep 2.seconds
        client.heartbeats.should eq 0
      ensure
        client.close
      end
    end
  end

  it "closes an unresponsive client after two heartbeat intervals, not before" do
    with_server do |_server, amqp_url|
      client = HeartbeatCountingClient.new(amqp_url, 6_u16)
      begin
        sleep 10.5.seconds
        client.disconnected?.should be_false, "Proxy closed the connection before 2x the heartbeat interval"
        wait_until(6.seconds) { client.disconnected? }.should be_true, "Proxy didn't close the unresponsive connection"
      ensure
        client.close
      end
    end
  end
end
