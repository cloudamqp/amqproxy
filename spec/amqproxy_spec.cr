require "./spec_helper"

describe AMQProxy::Server do
  it "keeps connections open" do
    s = AMQProxy::Server.new("127.0.0.1", 5672, false, Logger::ERROR)
    spawn { s.listen("127.0.0.1", 5673) }
    sleep 0.001
    10.times do
      AMQP::Client.start("amqp://localhost:5673") do |conn|
        conn.channel
        s.client_connections.should eq(1)
        s.upstream_connections.should eq(1)
      end
    end
    sleep 0.001
    s.client_connections.should eq(0)
    s.upstream_connections.should eq(1)
    s.close
  end

  it "can reconnect if upstream closes" do
    system "while (nc localhost 5673 -w 1); do sleep 1; done"
    s = AMQProxy::Server.new("127.0.0.1", 5672, false, Logger::ERROR)
    spawn { s.listen("127.0.0.1", 5673) }
    sleep 0.001
    AMQP::Client.start("amqp://localhost:5673") do |conn|
      conn.channel
      system "rabbitmqctl stop_app > /dev/null"
    end
    system "rabbitmqctl start_app > /dev/null"
    AMQP::Client.start("amqp://localhost:5673") do |conn|
      conn.channel
      s.client_connections.should eq(1)
      s.upstream_connections.should eq(1)
    end
    sleep 0.001
    s.client_connections.should eq(0)
    s.upstream_connections.should eq(1)
    s.close
  end
end
