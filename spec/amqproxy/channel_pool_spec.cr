require "../spec_helper"

# AMQP server that can be slow to accept connections and may not open channels
class SlowUpstream
  getter port : Int32
  getter connections = 0
  getter publishes = 0
  # Connections, from the first, that never get Connection#Start
  property stalled_connections = 0
  property start_delay = Time::Span.zero
  property channel_max = UInt16::MAX
  property? send_open_ok = true
  property? refuse_channels = false
  property? close_after_open_ok = false
  # Like RabbitMQ does with a publishing connection during a resource alarm
  property? stop_reading_on_publish = false
  @sockets = Array(TCPSocket).new
  @reading_resumed = Channel(Nil).new

  FRAME_MAX = 131_072_u32

  def initialize
    @tcp = TCPServer.new("127.0.0.1", 0)
    @port = @tcp.local_address.port
    spawn accept_loop, name: "SlowUpstream#accept_loop"
  end

  def resume_reading
    @reading_resumed.close
  end

  def close
    resume_reading
    @tcp.close
    @sockets.each &.close
  end

  private def accept_loop
    while socket = @tcp.accept?
      @sockets << socket
      @connections += 1
      next if @connections <= @stalled_connections
      spawn handle(socket), name: "SlowUpstream#handle"
    end
  end

  private def handle(socket : TCPSocket)
    socket.sync = false
    stream = AMQ::Protocol::Stream.new(socket, FRAME_MAX)
    negotiate(socket, stream)
    loop do
      case frame = stream.next_frame
      when AMQ::Protocol::Frame::Channel::Open
        if @refuse_channels
          send socket, AMQ::Protocol::Frame::Channel::Close.new(frame.channel, 406_u16, "PRECONDITION_FAILED - refused", 20_u16, 10_u16)
        elsif @send_open_ok
          open_ok = AMQ::Protocol::Frame::Channel::OpenOk.new(frame.channel)
          if @close_after_open_ok # in one write, so the proxy reads both at once
            socket.write_bytes open_ok, IO::ByteFormat::NetworkEndian
            send socket, AMQ::Protocol::Frame::Channel::Close.new(frame.channel, 406_u16, "PRECONDITION_FAILED - closed", 0_u16, 0_u16)
          else
            send socket, open_ok
          end
        end
      when AMQ::Protocol::Frame::Channel::Close
        send socket, AMQ::Protocol::Frame::Channel::CloseOk.new(frame.channel)
      when AMQ::Protocol::Frame::Basic::Publish
        @publishes += 1
        @reading_resumed.receive? if @stop_reading_on_publish
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
    sleep @start_delay
    send socket, AMQ::Protocol::Frame::Connection::Start.new
    stream.next_frame.as(AMQ::Protocol::Frame::Connection::StartOk)
    send socket, AMQ::Protocol::Frame::Connection::Tune.new(@channel_max, FRAME_MAX, 0_u16)
    stream.next_frame.as(AMQ::Protocol::Frame::Connection::TuneOk)
    stream.next_frame.as(AMQ::Protocol::Frame::Connection::Open)
    send socket, AMQ::Protocol::Frame::Connection::OpenOk.new
  end

  private def send(socket, frame)
    socket.write_bytes frame, IO::ByteFormat::NetworkEndian
    socket.flush
  end
end

# Raw AMQP client, to see exactly which frames the proxy sends, in order
class RawClient
  FRAME_MAX = 131_072_u32

  def initialize(url : String)
    uri = URI.parse(url)
    @socket = TCPSocket.new(uri.hostname || "127.0.0.1", uri.port || 5672)
    @socket.sync = false
    @socket.read_timeout = 5.seconds # fail instead of hang
    @stream = AMQ::Protocol::Stream.new(@socket, FRAME_MAX)
    @socket.write AMQ::Protocol::PROTOCOL_START_0_9_1.to_slice
    @socket.flush
    next_frame.as(AMQ::Protocol::Frame::Connection::Start)
    send AMQ::Protocol::Frame::Connection::StartOk.new(client_properties: AMQ::Protocol::Table.new,
      mechanism: "PLAIN", response: "\u0000guest\u0000guest", locale: "en_US")
    next_frame.as(AMQ::Protocol::Frame::Connection::Tune)
    send AMQ::Protocol::Frame::Connection::TuneOk.new(UInt16::MAX, FRAME_MAX, 0_u16)
    send AMQ::Protocol::Frame::Connection::Open.new(vhost: "/")
    next_frame.as(AMQ::Protocol::Frame::Connection::OpenOk)
  end

  def next_frame : AMQ::Protocol::Frame
    @stream.next_frame
  end

  def send(frame)
    @socket.write_bytes frame, IO::ByteFormat::NetworkEndian
    @socket.flush
  end

  def close
    @socket.close rescue nil
  end
end

describe AMQProxy::ChannelPool do
  it "times out when the upstream doesn't answer" do
    upstream = SlowUpstream.new
    upstream.stalled_connections = Int32::MAX
    begin
      with_proxy_to(upstream.port, connect_timeout: 0.5.seconds) do |proxy_url|
        AMQP::Client.start(proxy_url) do |conn|
          expect_raises(AMQP::Client::Error, /Timeout connecting to upstream/) do
            conn.channel
          end
        end
      end
    ensure
      upstream.close
    end
  end

  it "opens channels on another upstream connection while one is connecting" do
    upstream = SlowUpstream.new
    upstream.stalled_connections = 1
    begin
      with_proxy_to(upstream.port, max_upstream_channels: 1_u16, connect_timeout: 2.seconds) do |proxy_url|
        first = Channel(Exception?).new(1)
        spawn do
          AMQP::Client.start(proxy_url, &.channel)
          first.send nil
        rescue ex
          first.send ex
        end
        wait_until { upstream.connections == 1 }.should be_true

        opened = Channel(Nil).new(1)
        spawn do
          AMQP::Client.start(proxy_url) do |conn|
            conn.channel
            opened.send nil
          end
        end
        select
        when opened.receive
        when timeout(1.second)
          fail "No channel opened while the first upstream connection was connecting"
        end
        upstream.connections.should eq 2
        first.receive.should be_a(AMQP::Client::Error)
      end
    ensure
      upstream.close
    end
  end

  it "forwards frames before the upstream has opened the channel" do
    upstream = SlowUpstream.new
    upstream.send_open_ok = false
    begin
      with_proxy_to(upstream.port) do |proxy_url|
        AMQP::Client.start(proxy_url) do |conn|
          conn.channel.basic_publish("msg", "", "q")
          wait_until { upstream.publishes == 1 }.should be_true
        end
      end
    ensure
      upstream.close
    end
  end

  it "sends Channel#OpenOk before other frames on the channel" do
    upstream = SlowUpstream.new
    upstream.close_after_open_ok = true
    begin
      with_proxy_to(upstream.port) do |proxy_url|
        client = RawClient.new(proxy_url)
        begin
          client.send AMQ::Protocol::Frame::Channel::Open.new(1_u16)
          client.next_frame.should be_a(AMQ::Protocol::Frame::Channel::OpenOk)
          client.next_frame.should be_a(AMQ::Protocol::Frame::Channel::Close)
        ensure
          client.close
        end
      end
    ensure
      upstream.close
    end
  end

  it "sends Channel#OpenOk while a write to the upstream is blocked" do
    upstream = SlowUpstream.new
    upstream.stop_reading_on_publish = true
    begin
      with_proxy_to(upstream.port) do |proxy_url|
        publisher = AMQP::Client.new(proxy_url).connect
        channel = publisher.channel
        published = Channel(Nil).new
        spawn do
          body = Bytes.new(1024 * 1024)
          64.times { channel.basic_publish(body, "", "q") } # more than the socket buffers hold
        rescue IO::Error | AMQP::Client::Error
        ensure
          published.close
        end
        sleep 0.5.seconds # until the proxy's write to the upstream blocks

        result = Channel(AMQP::Client::Connection | Exception).new(1)
        spawn do
          conn = AMQP::Client.new(proxy_url).connect
          conn.channel
          result.send conn
        rescue ex
          result.send ex
        end
        conn = select
        when r = result.receive
          r.should be_a(AMQP::Client::Connection)
          r.as(AMQP::Client::Connection)
        when timeout(3.seconds)
          fail "Channel#OpenOk waits for the blocked write"
        end
        upstream.connections.should eq 1 # the channel is on the blocked connection

        upstream.resume_reading
        published.receive?
        conn.close
      end
    ensure
      upstream.close
    end
  end

  it "closes the client channel when the upstream refuses to open it" do
    upstream = SlowUpstream.new
    upstream.refuse_channels = true
    begin
      with_proxy_to(upstream.port) do |proxy_url|
        AMQP::Client.start(proxy_url) do |conn|
          channel = conn.channel
          wait_until { channel.closed? }.should be_true
          expect_raises(AMQP::Client::Channel::ClosedException, /406 - PRECONDITION_FAILED - refused/) do
            channel.queue_declare("q")
          end
          upstream.refuse_channels = false
          conn.channel
        end
      end
    ensure
      upstream.close
    end
  end

  it "opens the channel on another upstream when the server allows fewer channels" do
    upstream = SlowUpstream.new
    upstream.start_delay = 0.3.seconds # so that all clients wait for the first connection
    upstream.channel_max = 1_u16
    begin
      with_proxy_to(upstream.port, connect_timeout: 3.seconds) do |proxy_url|
        done = Channel(Exception?).new(3)
        3.times do
          spawn do
            AMQP::Client.start(proxy_url) do |conn|
              conn.channel
              sleep 0.5.seconds # keep it open until all clients have one
            end
            done.send nil
          rescue ex
            done.send ex
          end
        end
        3.times { done.receive.should be_nil }
        upstream.connections.should eq 3
      end
    ensure
      upstream.close
    end
  end

  it "limits connecting upstreams to the channel_max of the latest connection" do
    upstream = SlowUpstream.new
    upstream.channel_max = 1_u16
    begin
      with_proxy_to(upstream.port, connect_timeout: 3.seconds) do |proxy_url|
        AMQP::Client.start(proxy_url) do |conn|
          conn.channel # the only connection is now full
          upstream.start_delay = 0.5.seconds
          started = Time.instant
          opened = Channel(Exception?).new(3)
          release = Channel(Nil).new
          3.times do
            spawn do
              AMQP::Client.start(proxy_url) do |client|
                client.channel
                opened.send nil
                release.receive? # keep it open, a freed slot could be reused
              end
            rescue ex
              opened.send ex
            end
          end
          3.times { opened.receive.should be_nil }
          # one at a time they would take 3 start delays
          (Time.instant - started).should be < 1.second
          release.close
          upstream.connections.should eq 4
        end
      end
    ensure
      upstream.close
    end
  end

  it "lets a connected upstream use its own channel_max" do
    upstream = SlowUpstream.new
    upstream.channel_max = 2_u16
    begin
      with_proxy_to(upstream.port) do |proxy_url|
        AMQP::Client.start(proxy_url) do |conn|
          first = conn.channel
          conn.channel
          upstream.channel_max = 1_u16
          conn.channel
          upstream.connections.should eq 2

          first.close
          conn.channel
          upstream.connections.should eq 2
        end
      end
    ensure
      upstream.close
    end
  end

  it "keeps the channel_max of each pool apart" do
    upstream = SlowUpstream.new
    upstream.channel_max = 1_u16
    begin
      with_proxy_to(upstream.port, connect_timeout: 3.seconds) do |proxy_url|
        AMQP::Client.start(proxy_url, &.channel)
        upstream.channel_max = UInt16::MAX
        upstream.start_delay = 0.3.seconds
        other_url = proxy_url.sub("amqp://", "amqp://other:secret@")
        done = Channel(Exception?).new(3)
        3.times do
          spawn do
            AMQP::Client.start(other_url, &.channel)
            done.send nil
          rescue ex
            done.send ex
          end
        end
        3.times { done.receive.should be_nil }
        upstream.connections.should eq 2
      end
    ensure
      upstream.close
    end
  end
end
