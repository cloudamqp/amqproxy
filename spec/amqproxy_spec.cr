require "./spec_helper"

describe AMQProxy::Server do
  it "graceful shutdown" do
    started = Time.utc.to_unix

    s = AMQProxy::Server.new("127.0.0.1", 5672, false, Logger::DEBUG, 5, true)
    channel = Channel(Nil).new
    spawn do
      s.listen("127.0.0.1", 5673)
      channel.send(nil) # send 6
    end
    Fiber.yield
    spawn do
      AMQP::Client.start("amqp://localhost:5673") do |conn|
        conn.channel
        channel.send(nil) # send 0
        10.times do
          s.client_connections.should be >= 1
          s.upstream_connections.should be >= 1
          sleep 1
        end
      end
      channel.send(nil) # send 5
    end
    channel.receive # wait 0
    s.client_connections.should eq 1
    s.upstream_connections.should eq 1
    spawn do
      AMQP::Client.start("amqp://localhost:5673") do |conn|
        conn.channel
        channel.send(nil) # send 2
        sleep 2
      end
      channel.send(nil) # send 3
    end
    channel.receive # wait 2
    s.client_connections.should eq 2
    s.upstream_connections.should eq 2
    spawn s.close
    channel.receive # wait 3
    s.client_connections.should eq 1
    s.upstream_connections.should eq 2 # since connection stays open
    channel_test = Channel(Bool).new
    spawn do
      begin
        AMQP::Client.start("amqp://localhost:5673") do |conn|
          conn.channel
          channel_test.send(false) # send 4
          sleep 1
        end
      rescue ex
        puts ex.message
        # ex.message.should be "Error reading socket: Connection reset by peer"
        channel_test.send(true) # send 4
      end
    end
    Fiber.yield
    channel_test.receive.should be_true # wait 4
    s.client_connections.should eq 1 # since the new connection should not have worked
    s.upstream_connections.should eq 2 # since connections stay open
    channel.receive # wait 5
    s.running.should eq true
    s.client_connections.should eq 0 # since now the server should be closed
    s.upstream_connections.should eq 1
    channel.receive # wait 6
    s.client_connections.should eq 0
    s.upstream_connections.should eq 0
    s.running.should eq false
    (Time.utc.to_unix - started).should be < 30
  end

  it "keeps connections open" do
    s = AMQProxy::Server.new("127.0.0.1", 5672, false, Logger::DEBUG)
    begin
      spawn { s.listen("127.0.0.1", 5673) }
      Fiber.yield
      10.times do
        AMQP::Client.start("amqp://localhost:5673") do |conn|
          conn.channel
          s.client_connections.should eq 1
          s.upstream_connections.should eq 1
        end
        sleep 0.1
      end
      s.client_connections.should eq 0
      s.upstream_connections.should eq 1
    ensure
      s.close
    end
  end

  it "can reconnect if upstream closes" do
    s = AMQProxy::Server.new("127.0.0.1", 5672, false, Logger::DEBUG)
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
      s.close
    end
  end

  it "responds to upstream heartbeats" do
    system("#{MAYBE_SUDO}rabbitmqctl eval 'application:set_env(rabbit, heartbeat, 1).' > /dev/null").should be_true
    s = AMQProxy::Server.new("127.0.0.1", 5672, false, Logger::DEBUG)
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
      s.close
      system("#{MAYBE_SUDO}rabbitmqctl eval 'application:set_env(rabbit, heartbeat, 60).' > /dev/null").should be_true
    end
  end
end
