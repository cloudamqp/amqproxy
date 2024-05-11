require "./spec_helper"

describe AMQProxy::Server do
  it "dont reuse channels closed by upstream" do
    s = AMQProxy::Server.new("127.0.0.1", 5672, false)
    begin
      spawn { s.listen("127.0.0.1", 5673) }
      Fiber.yield
      AMQP::Client.start("amqp://localhost:5673") do |conn|
        ch = conn.channel
        ch.basic_publish "foobar", "non-existing"
      end
      AMQP::Client.start("amqp://localhost:5673") do |conn|
        ch = conn.channel
        ch.basic_publish_confirm "foobar", "amq.fanout"
      end
      AMQP::Client.start("amqp://localhost:5673") do |conn|
        ch = conn.channel
        expect_raises(AMQP::Client::Channel::ClosedException) do
          ch.basic_publish_confirm "foobar", "non-existing"
        end
      end
      sleep 0.1
      s.upstream_connections.should eq 1
    ensure
      s.stop_accepting_clients
    end
  end

  it "keeps connections open" do
    s = AMQProxy::Server.new("127.0.0.1", 5672, false)
    begin
      spawn { s.listen("127.0.0.1", 5673) }
      Fiber.yield
      10.times do
        AMQP::Client.start("amqp://localhost:5673") do |conn|
          ch = conn.channel
          ch.basic_publish "foobar", "amq.fanout", ""
          s.client_connections.should eq 1
          s.upstream_connections.should eq 1
        end
      end
      s.client_connections.should eq 0
      s.upstream_connections.should eq 1
    ensure
      s.stop_accepting_clients
    end
  end

  it "publish and consume works" do
    server = AMQProxy::Server.new("127.0.0.1", 5672, false)
    begin
      spawn { server.listen("127.0.0.1", 5673) }
      Fiber.yield

      queue_name = "amqproxy-test-queue"
      message_payload = "Message from AMQProxy specs"
      num_received_messages = 0
      num_messages_to_publish = 5

      num_messages_to_publish.times do
        AMQP::Client.start("amqp://localhost:5673") do |conn|
          channel = conn.channel
          queue = channel.queue(queue_name)
          queue.publish_confirm(message_payload)
        end
      end
      sleep 0.1

      AMQP::Client.start("amqp://localhost:5673") do |conn|
        channel = conn.channel
        channel.basic_consume(queue_name, no_ack: false, tag: "AMQProxy specs") do |msg|
          body = msg.body_io.to_s
          if body == message_payload
            channel.basic_ack(msg.delivery_tag)
            num_received_messages += 1
          end
        end
        sleep 0.1
      end

      num_received_messages.should eq num_messages_to_publish
    ensure
      server.stop_accepting_clients
    end
  end

  it "a client can open all channels" do
    s = AMQProxy::Server.new("127.0.0.1", 5672, false)
    begin
      spawn { s.listen("127.0.0.1", 5673) }
      Fiber.yield
      max = 4000
      AMQP::Client.start("amqp://localhost:5673?channel_max=#{max}") do |conn|
        conn.channel_max.should eq max
        conn.channel_max.times do
          conn.channel
        end
        s.client_connections.should eq 1
        s.upstream_connections.should eq 2
      end
      sleep 0.1
      s.client_connections.should eq 0
      s.upstream_connections.should eq 2
    ensure
      s.stop_accepting_clients
    end
  end

  it "can reconnect if upstream closes" do
    s = AMQProxy::Server.new("127.0.0.1", 5672, false)
    begin
      spawn { s.listen("127.0.0.1", 5673) }
      Fiber.yield
      AMQP::Client.start("amqp://localhost:5673") do |conn|
        conn.channel
        system("#{MAYBE_SUDO}rabbitmqctl stop_app > /dev/null").should be_true
      end
      system("#{MAYBE_SUDO}rabbitmqctl start_app > /dev/null").should be_true
      AMQP::Client.start("amqp://localhost:5673") do |conn|
        conn.channel
        s.client_connections.should eq(1)
        s.upstream_connections.should eq(1)
      end
      sleep 0.1
      s.client_connections.should eq(0)
      s.upstream_connections.should eq(1)
    ensure
      s.stop_accepting_clients
    end
  end

  it "responds to upstream heartbeats" do
    system("#{MAYBE_SUDO}rabbitmqctl eval 'application:set_env(rabbit, heartbeat, 1).' > /dev/null").should be_true
    s = AMQProxy::Server.new("127.0.0.1", 5672, false)
    begin
      spawn { s.listen("127.0.0.1", 5673) }
      Fiber.yield
      AMQP::Client.start("amqp://localhost:5673") do |conn|
        conn.channel
      end
      sleep 2
      s.client_connections.should eq(0)
      s.upstream_connections.should eq(1)
    ensure
      s.stop_accepting_clients
      system("#{MAYBE_SUDO}rabbitmqctl eval 'application:set_env(rabbit, heartbeat, 60).' > /dev/null").should be_true
    end
  end

  it "supports waiting for client connections on graceful shutdown" do
    started = Time.utc.to_unix

    s = AMQProxy::Server.new("127.0.0.1", 5672, false, 5)
    wait_for_channel = Channel(Int32).new # channel used to wait for certain calls, to test certain behaviour
    spawn do
      s.listen("127.0.0.1", 5673)
    end
    Fiber.yield
    spawn do
      AMQP::Client.start("amqp://localhost:5673") do |conn|
        conn.channel
        wait_for_channel.send(0) # send 0
        10.times do
          s.client_connections.should be >= 1
          s.upstream_connections.should be >= 1
          sleep 1
        end
      end
      wait_for_channel.send(5) # send 5
    end
    wait_for_channel.receive.should eq 0 # wait 0
    s.client_connections.should eq 1
    s.upstream_connections.should eq 1
    spawn do
      AMQP::Client.start("amqp://localhost:5673") do |conn|
        conn.channel
        wait_for_channel.send(2) # send 2
        sleep 2
      end
      wait_for_channel.send(3) # send 3
    end
    wait_for_channel.receive.should eq 2 # wait 2
    s.client_connections.should eq 2
    s.upstream_connections.should eq 1
    spawn s.stop_accepting_clients
    wait_for_channel.receive.should eq 3 # wait 3
    s.client_connections.should eq 1
    s.upstream_connections.should eq 1 # since connection stays open
    spawn do
      begin
        AMQP::Client.start("amqp://localhost:5673") do |conn|
          conn.channel
          wait_for_channel.send(-1) # send 4 (this should not happen)
          sleep 1
        end
      rescue ex
        # ex.message.should be "Error reading socket: Connection reset by peer"
        wait_for_channel.send(4) # send 4
      end
    end
    wait_for_channel.receive.should eq 4 # wait 4
    s.client_connections.should eq 1     # since the new connection should not have worked
    s.upstream_connections.should eq 1   # since connections stay open
    wait_for_channel.receive.should eq 5 # wait 5
    s.client_connections.should eq 0     # since now the server should be closed
    s.upstream_connections.should eq 1
    (Time.utc.to_unix - started).should be < 30
  end

  it "works after server closes channel" do
    s = AMQProxy::Server.new("127.0.0.1", 5672, false)
    begin
      spawn { s.listen("127.0.0.1", 5673) }
      Fiber.yield
      AMQP::Client.start("amqp://localhost:5673") do |conn|
        qname = "test#{rand}"
        3.times do
          expect_raises(AMQP::Client::Channel::ClosedException) do
            ch = conn.channel
            ch.basic_consume(qname) { }
          end
        end
      end
    ensure
      s.stop_accepting_clients
    end
  end

  it "passes connection blocked frames to clients" do
    s = AMQProxy::Server.new("127.0.0.1", 5672, false)
    done = Channel(Nil).new
    begin
      spawn { s.listen("127.0.0.1", 5673) }
      Fiber.yield
      AMQP::Client.start("amqp://localhost:5673") do |conn|
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
    ensure
      s.stop_accepting_clients
    end
  end

  it "supports publishing large messages" do
    s = AMQProxy::Server.new("127.0.0.1", 5672, false)
    begin
      spawn { s.listen("127.0.0.1", 5673) }
      Fiber.yield
      AMQP::Client.start("amqp://localhost:5673") do |conn|
        ch = conn.channel
        q = ch.queue
        q.publish_confirm Bytes.new(10240)
        msg = q.get.not_nil!("should not be nil")
        msg.body_io.bytesize.should eq 10240
      end
    ensure
      s.stop_accepting_clients
    end
  end
end
