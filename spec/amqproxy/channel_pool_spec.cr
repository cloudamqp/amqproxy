require "../spec_helper"

# AMQP server that can be slow to accept connections and to open channels
class SlowUpstream
  getter port : Int32
  getter connections = 0
  getter channel_closes = 0
  # Connections, from the first, that never get Connection#Start
  property stalled_connections = 0
  property start_delay = Time::Span.zero
  property channel_max = UInt16::MAX
  # Delay before Channel#OpenOk, nil to never send it
  property open_ok_delay : Time::Span? = Time::Span.zero
  property? refuse_channels = false
  @sockets = Array(TCPSocket).new

  FRAME_MAX = 131_072_u32

  def initialize
    @tcp = TCPServer.new("127.0.0.1", 0)
    @port = @tcp.local_address.port
    spawn accept_loop, name: "SlowUpstream#accept_loop"
  end

  def close
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
        elsif delay = @open_ok_delay
          sleep delay
          send socket, AMQ::Protocol::Frame::Channel::OpenOk.new(frame.channel)
        end
      when AMQ::Protocol::Frame::Channel::Close
        @channel_closes += 1
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

describe AMQProxy::ChannelPool do
  it "times out when the upstream doesn't answer" do
    upstream = SlowUpstream.new
    upstream.stalled_connections = Int32::MAX
    begin
      with_proxy_to(upstream.port, open_channel_timeout: 0.5.seconds) do |proxy_url|
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
      with_proxy_to(upstream.port, max_upstream_channels: 1_u16, open_channel_timeout: 2.seconds) do |proxy_url|
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

  it "waits for the upstream to open the channel" do
    upstream = SlowUpstream.new
    upstream.open_ok_delay = 0.3.seconds
    begin
      with_proxy_to(upstream.port) do |proxy_url|
        AMQP::Client.start(proxy_url) do |conn|
          started = Time.instant
          conn.channel
          (Time.instant - started).should be >= 0.3.seconds
        end
      end
    ensure
      upstream.close
    end
  end

  it "closes a channel that the upstream didn't open in time" do
    upstream = SlowUpstream.new
    upstream.open_ok_delay = nil
    begin
      with_proxy_to(upstream.port, open_channel_timeout: 0.5.seconds) do |proxy_url|
        AMQP::Client.start(proxy_url) do |conn|
          expect_raises(AMQP::Client::Channel::ClosedException, /Timeout waiting for upstream to open channel/) do
            conn.channel
          end
          wait_until { upstream.channel_closes == 1 }.should be_true

          upstream.open_ok_delay = Time::Span.zero
          conn.channel
          upstream.connections.should eq 1
        end
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
          expect_raises(AMQP::Client::Channel::ClosedException, /406 - PRECONDITION_FAILED - refused/) do
            conn.channel
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
      with_proxy_to(upstream.port, open_channel_timeout: 3.seconds) do |proxy_url|
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
      with_proxy_to(upstream.port, open_channel_timeout: 3.seconds) do |proxy_url|
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
      with_proxy_to(upstream.port, open_channel_timeout: 3.seconds) do |proxy_url|
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
