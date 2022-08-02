require "./spec_helper"

describe AMQProxy::Server do
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
      s.stop_accepting_clients
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
      s.stop_accepting_clients
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
      s.stop_accepting_clients
      system("#{MAYBE_SUDO}rabbitmqctl eval 'application:set_env(rabbit, heartbeat, 60).' > /dev/null").should be_true
    end
  end
end
