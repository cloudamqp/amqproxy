require "./spec_helper"

private def with_server(& : UDPSocket ->)
  server = UDPSocket.new
  server.bind("localhost", 1234)
  yield server
ensure
  server.close if server
end

describe AMQProxy::Server do
  describe "statsd" do
    it "sends client connections statsd metrics" do
      with_server do |statsd_server|
        logger = Logger.new(STDOUT)
        logger.level = Logger::DEBUG
        statsd_client = AMQProxy::StatsdClient.new(logger, "localhost", 1234)
        s = AMQProxy::Server.new("127.0.0.1", 5672, false, statsd_client, logger)
        begin
          spawn { s.listen("127.0.0.1", 5673) }
          Fiber.yield
          i = 0
          10.times do
            i = i + 1
            AMQP::Client.start("amqp://localhost:5673") do |conn|
              conn.channel

              # This is also testing that connection pooling is working
              if i == 1
                expected_message = "amqproxy.connections.upstream.created:1|c|@1"
                statsd_server.gets(expected_message.bytesize).should eq expected_message
              end

              expected_message = "amqproxy.connections.client.total:1|g"
              statsd_server.gets(expected_message.bytesize).should eq expected_message

              expected_message = "amqproxy.connections.client.created:1|c|@1"
              statsd_server.gets(expected_message.bytesize).should eq expected_message
            end

            expected_message = "amqproxy.connections.client.total:0|g"
            statsd_server.gets(expected_message.bytesize).should eq expected_message

            expected_message = "amqproxy.connections.client.disconnected:1|c|@1"
            statsd_server.gets(expected_message.bytesize).should eq expected_message

            sleep 0.1
          end
        ensure
          s.close
        end
      end
    end
  end

  it "keeps connections open" do
    logger = Logger.new(STDOUT)
    logger.level = Logger::DEBUG
    s = AMQProxy::Server.new("127.0.0.1", 5672, false, AMQProxy::DummyMetricsClient.new, logger)
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
    logger = Logger.new(STDOUT)
    logger.level = Logger::DEBUG
    s = AMQProxy::Server.new("127.0.0.1", 5672, false, AMQProxy::DummyMetricsClient.new, logger)
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

  it "supports waiting for client connections on graceful shutdown" do
    started = Time.utc.to_unix

    s = AMQProxy::Server.new("127.0.0.1", 5672, false, Logger::DEBUG, 5)
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
    s.upstream_connections.should eq 2
    spawn s.stop_accepting_clients
    wait_for_channel.receive.should eq 3 # wait 3
    s.client_connections.should eq 1
    s.upstream_connections.should eq 2 # since connection stays open
    spawn do
      begin
        AMQP::Client.start("amqp://localhost:5673") do |conn|
          conn.channel
          wait_for_channel.send(-1) # send 4 (this should not happen)
          sleep 1
        end
      rescue ex
        puts ex.message
        # ex.message.should be "Error reading socket: Connection reset by peer"
        wait_for_channel.send(4) # send 4
      end
    end
    wait_for_channel.receive.should eq 4 # wait 4
    s.client_connections.should eq 1     # since the new connection should not have worked
    s.upstream_connections.should eq 2   # since connections stay open
    wait_for_channel.receive.should eq 5 # wait 5
    s.client_connections.should eq 0     # since now the server should be closed
    s.upstream_connections.should eq 1
    (Time.utc.to_unix - started).should be < 30
  end
end
