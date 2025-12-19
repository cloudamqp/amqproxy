require "../spec_helper"

describe AMQProxy::Server do
  it "dont reuse channels closed by upstream" do
    with_server do |server, proxy_url|
      Fiber.yield
      AMQP::Client.start(proxy_url) do |conn|
        ch = conn.channel
        ch.basic_publish "foobar", "non-existing"
      end
      AMQP::Client.start(proxy_url) do |conn|
        ch = conn.channel
        ch.basic_publish_confirm "foobar", "amq.fanout"
      end
      AMQP::Client.start(proxy_url) do |conn|
        ch = conn.channel
        expect_raises(AMQP::Client::Channel::ClosedException) do
          ch.basic_publish_confirm "foobar", "non-existing"
        end
      end
      sleep 0.1.seconds
      server.upstream_connections.should eq 1
    end
  end

  it "keeps connections open" do
    with_server do |server, proxy_url|
      Fiber.yield
      10.times do
        AMQP::Client.start(proxy_url) do |conn|
          ch = conn.channel
          ch.basic_publish "foobar", "amq.fanout", ""
          server.client_connections.should eq 1
          server.upstream_connections.should eq 1
        end
      end
      server.client_connections.should eq 0
      server.upstream_connections.should eq 1
    end
  end

  it "publish and consume works" do
    with_server do |_server, proxy_url|
      Fiber.yield

      queue_name = "amqproxy-test-queue"
      message_payload = "Message from AMQProxy specs"
      num_received_messages = 0
      num_messages_to_publish = 5

      num_messages_to_publish.times do
        AMQP::Client.start(proxy_url) do |conn|
          channel = conn.channel
          queue = channel.queue(queue_name)
          queue.publish_confirm(message_payload)
        end
      end
      sleep 0.1.seconds

      AMQP::Client.start(proxy_url) do |conn|
        channel = conn.channel
        channel.basic_consume(queue_name, no_ack: false, tag: "AMQProxy specs") do |msg|
          body = msg.body_io.to_s
          if body == message_payload
            channel.basic_ack(msg.delivery_tag)
            num_received_messages += 1
          end
        end
        sleep 0.1.seconds
      end

      num_received_messages.should eq num_messages_to_publish
    end
  end

  it "a client can open all channels" do
    with_server do |server, proxy_url|
      max = 4000
      AMQP::Client.start("#{proxy_url}?channel_max=#{max}") do |conn|
        conn.channel_max.should eq max
        conn.channel_max.times do
          conn.channel
        end
        server.client_connections.should eq 1
        server.upstream_connections.should eq 2
      end
      sleep 0.1.seconds
      server.client_connections.should eq 0
      server.upstream_connections.should eq 2
    end
  end

  it "can reconnect if upstream closes" do
    with_server do |server, proxy_url|
      Fiber.yield
      AMQP::Client.start(proxy_url) do |conn|
        conn.channel
        system("#{MAYBE_SUDO}rabbitmqctl stop_app > /dev/null").should be_true
      end
      system("#{MAYBE_SUDO}rabbitmqctl start_app > /dev/null").should be_true
      AMQP::Client.start(proxy_url) do |conn|
        conn.channel
        server.client_connections.should eq(1)
        server.upstream_connections.should eq(1)
      end
      sleep 0.1.seconds
      server.client_connections.should eq(0)
      server.upstream_connections.should eq(1)
    end
  end

  it "responds to upstream heartbeats" do
    with_server do |server, proxy_url|
      system("#{MAYBE_SUDO}rabbitmqctl eval 'application:set_env(rabbit, heartbeat, 1).' > /dev/null").should be_true
      Fiber.yield
      AMQP::Client.start(proxy_url) do |conn|
        conn.channel
      end
      sleep 2.seconds
      server.client_connections.should eq(0)
      server.upstream_connections.should eq(1)
    ensure
      system("#{MAYBE_SUDO}rabbitmqctl eval 'application:set_env(rabbit, heartbeat, 60).' > /dev/null").should be_true
    end
  end

  it "supports waiting for client connections on graceful shutdown" do
    started = Time.utc.to_unix

    with_server(idle_connection_timeout: 5) do |server, proxy_url|
      wait_for_channel = Channel(Int32).new # channel used to wait for certain calls, to test certain behaviour
      Fiber.yield
      spawn do
        AMQP::Client.start(proxy_url) do |conn|
          conn.channel
          wait_for_channel.send(0) # send 0
          10.times do
            server.client_connections.should be >= 1
            server.upstream_connections.should be >= 1
            sleep 1.seconds
          end
        end
        wait_for_channel.send(5) # send 5
      end
      wait_for_channel.receive.should eq 0 # wait 0
      server.client_connections.should eq 1
      server.upstream_connections.should eq 1
      spawn do
        AMQP::Client.start(proxy_url) do |conn|
          conn.channel
          wait_for_channel.send(2) # send 2
          sleep 2.seconds
        end
        wait_for_channel.send(3) # send 3
      end
      wait_for_channel.receive.should eq 2 # wait 2
      server.client_connections.should eq 2
      server.upstream_connections.should eq 1
      spawn server.stop_accepting_clients
      wait_for_channel.receive.should eq 3 # wait 3
      server.client_connections.should eq 1
      server.upstream_connections.should eq 1 # since connection stays open
      spawn do
        begin
          AMQP::Client.start(proxy_url) do |conn|
            conn.channel
            wait_for_channel.send(-1) # send 4 (this should not happen)
            sleep 1.seconds
          end
        rescue ex
          # ex.message.should be "Error reading socket: Connection reset by peer"
          wait_for_channel.send(4) # send 4
        end
      end
      wait_for_channel.receive.should eq 4    # wait 4
      server.client_connections.should eq 1   # since the new connection should not have worked
      server.upstream_connections.should eq 1 # since connections stay open
      wait_for_channel.receive.should eq 5    # wait 5
      server.client_connections.should eq 0   # since now the server should be closed
      server.upstream_connections.should eq 1
      (Time.utc.to_unix - started).should be < 30
    end
  end

  it "works after server closes channel" do
    with_server do |_server, proxy_url|
      Fiber.yield
      AMQP::Client.start(proxy_url) do |conn|
        qname = "test#{rand}"
        3.times do
          expect_raises(AMQP::Client::Channel::ClosedException) do
            ch = conn.channel
            ch.basic_consume(qname) { }
          end
        end
      end
    end
  end

  it "passes connection blocked frames to clients" do
    with_server do |_server, proxy_url|
      done = Channel(Nil).new
      Fiber.yield
      AMQP::Client.start(proxy_url) do |conn|
        conn.on_blocked do
          done.send nil
          system("#{MAYBE_SUDO}rabbitmqctl set_vm_memory_high_watermark 0.8 > /dev/null").should be_true
        end
        conn.on_unblocked do
          done.send nil
        end
        ch = conn.channel
        system("#{MAYBE_SUDO}rabbitmqctl set_vm_memory_high_watermark 0.001 > /dev/null").should be_true
        ch.basic_publish "foobar", "amq.fanout"
        2.times { done.receive }
      end
    end
  end

  it "supports publishing large messages" do
    with_server do |_server, proxy_url|
      Fiber.yield
      AMQP::Client.start(proxy_url) do |conn|
        ch = conn.channel
        q = ch.queue
        q.publish_confirm Bytes.new(10240)
        msg = q.get.not_nil!("should not be nil")
        msg.body_io.bytesize.should eq 10240
      end
    end
  end

  it "supports publishing large messages when frame_max is small" do
    with_server do |_server, proxy_url|
      Fiber.yield
      AMQP::Client.start("#{proxy_url}?frame_max=4096") do |conn|
        ch = conn.channel
        q = ch.queue
        q.publish_confirm Bytes.new(200_000)
        msg = q.get.not_nil!("should not be nil")
        msg.body_io.bytesize.should eq 200_000
      end
    end
  end

  it "should treat all frames as heartbeats" do
    with_server do |server, proxy_url|
      Fiber.yield
      AMQP::Client.start("#{proxy_url}?heartbeat=1") do |conn|
        client = server.@clients.first?.should_not be_nil
        last_heartbeat = client.@last_heartbeat
        conn.channel
        Fiber.yield
        client.@last_heartbeat.should be > last_heartbeat
        last_heartbeat = client.@last_heartbeat
        conn.write AMQ::Protocol::Frame::Heartbeat.new
        Fiber.yield
        client.@last_heartbeat.should be > last_heartbeat
      end
    end
  end

  it "does not send duplicate channel.close frames when client crashes after sending close" do
    with_server do |server, proxy_url|
      Fiber.yield
      uri = URI.parse(proxy_url)

      # Open multiple channels and close them rapidly, then crash
      # This increases the probability of triggering the race condition
      num_channels = 10

      socket = TCPSocket.new(uri.host.not_nil!, uri.port.not_nil!)
      socket.sync = false

      # AMQP handshake
      socket.write AMQ::Protocol::PROTOCOL_START_0_9_1.to_slice
      socket.flush
      AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian)
      start_ok = AMQ::Protocol::Frame::Connection::StartOk.new(
        response: "\u0000guest\u0000guest",
        client_properties: AMQ::Protocol::Table.new,
        mechanism: "PLAIN",
        locale: "en_US"
      )
      socket.write_bytes start_ok, IO::ByteFormat::NetworkEndian
      socket.flush
      AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian)
      tune_ok = AMQ::Protocol::Frame::Connection::TuneOk.new(2047_u16, 131072_u32, 0_u16)
      socket.write_bytes tune_ok, IO::ByteFormat::NetworkEndian
      socket.flush
      open = AMQ::Protocol::Frame::Connection::Open.new(vhost: "/")
      socket.write_bytes open, IO::ByteFormat::NetworkEndian
      socket.flush
      AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian)

      # Open multiple channels
      1_u16.upto(num_channels.to_u16) do |ch_id|
        channel_open = AMQ::Protocol::Frame::Channel::Open.new(ch_id)
        socket.write_bytes channel_open, IO::ByteFormat::NetworkEndian
      end
      socket.flush

      # Read all Channel::OpenOk responses
      num_channels.times do
        AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian)
          .as(AMQ::Protocol::Frame::Channel::OpenOk)
      end

      sleep 0.1.seconds
      server.upstream_connections.should eq 1

      # Send Channel::Close for ALL channels rapidly without waiting for CloseOk
      1_u16.upto(num_channels.to_u16) do |ch_id|
        channel_close = AMQ::Protocol::Frame::Channel::Close.new(ch_id, 200_u16, "Normal close", 0_u16, 0_u16)
        socket.write_bytes channel_close, IO::ByteFormat::NetworkEndian
      end
      socket.flush

      # Simulate crash: close socket abruptly WITHOUT waiting for any CloseOk
      socket.close

      # Give the proxy time to process the disconnect
      sleep 0.3.seconds

      # The upstream connection should still be open
      # If duplicate Channel::Close was sent, upstream would have closed the connection
      # with error: "expected 'channel.open'"
      server.upstream_connections.should eq 1

      # Verify we can still use the upstream connection with another client
      AMQP::Client.start(proxy_url) do |conn|
        ch = conn.channel
        ch.basic_publish_confirm "test", "amq.fanout"
      end

      sleep 0.1.seconds
      server.upstream_connections.should eq 1
    end
  end

  it "does not send duplicate channel.close when upstream initiates close and client crashes" do
    with_server do |server, proxy_url|
      Fiber.yield
      uri = URI.parse(proxy_url)

      # Use low-level socket to control the exact frame sequence
      socket = TCPSocket.new(uri.host.not_nil!, uri.port.not_nil!)
      socket.sync = false

      # AMQP handshake
      socket.write AMQ::Protocol::PROTOCOL_START_0_9_1.to_slice
      socket.flush
      AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian)
      start_ok = AMQ::Protocol::Frame::Connection::StartOk.new(
        response: "\u0000guest\u0000guest",
        client_properties: AMQ::Protocol::Table.new,
        mechanism: "PLAIN",
        locale: "en_US"
      )
      socket.write_bytes start_ok, IO::ByteFormat::NetworkEndian
      socket.flush
      AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian)
      tune_ok = AMQ::Protocol::Frame::Connection::TuneOk.new(2047_u16, 131072_u32, 0_u16)
      socket.write_bytes tune_ok, IO::ByteFormat::NetworkEndian
      socket.flush
      open = AMQ::Protocol::Frame::Connection::Open.new(vhost: "/")
      socket.write_bytes open, IO::ByteFormat::NetworkEndian
      socket.flush
      AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian)

      # Open a channel
      channel_open = AMQ::Protocol::Frame::Channel::Open.new(1_u16)
      socket.write_bytes channel_open, IO::ByteFormat::NetworkEndian
      socket.flush
      AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian)

      # Now the upstream connection should exist (created when channel was opened)
      sleep 0.1.seconds
      server.upstream_connections.should eq 1

      # Trigger a channel error by consuming from non-existent queue
      # This will cause the upstream to send Channel::Close
      basic_consume = AMQ::Protocol::Frame::Basic::Consume.new(
        channel: 1_u16,
        reserved1: 0_u16,
        queue: "non_existent_queue_#{rand}",
        consumer_tag: "test",
        no_local: false,
        no_ack: false,
        exclusive: false,
        no_wait: false,
        arguments: AMQ::Protocol::Table.new
      )
      socket.write_bytes basic_consume, IO::ByteFormat::NetworkEndian
      socket.flush

      # Read the Channel::Close from the server (forwarded through proxy)
      frame = AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian)
      frame.should be_a(AMQ::Protocol::Frame::Channel::Close)

      # Simulate client crash: close socket WITHOUT sending CloseOk
      socket.close

      # Give the proxy time to process the disconnect
      sleep 0.2.seconds

      # The upstream connection should still be open
      # The proxy should have already sent CloseOk to upstream when it received Channel::Close
      server.upstream_connections.should eq 1

      # Verify we can still use the upstream connection
      AMQP::Client.start(proxy_url) do |conn|
        ch = conn.channel
        ch.basic_publish_confirm "test", "amq.fanout"
      end

      sleep 0.1.seconds
      server.upstream_connections.should eq 1
    end
  end
end
