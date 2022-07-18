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
      s.close
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
      s.close
    end
  end

  it "responds to upstream heartbeats" do
    logger = Logger.new(STDOUT)
    logger.level = Logger::DEBUG
    system("#{MAYBE_SUDO}rabbitmqctl eval 'application:set_env(rabbit, heartbeat, 1).' > /dev/null").should be_true
    s = AMQProxy::Server.new("127.0.0.1", 5672, false, AMQProxy::DummyMetricsClient.new, logger)
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
