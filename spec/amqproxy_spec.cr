require "./spec_helper"

describe AMQProxy::Server do
  it "keeps connections open" do
    s = AMQProxy::Server.new("127.0.0.1", 5672, false, Logger::ERROR)
    spawn { s.listen("127.0.0.1", 5673) }
    sleep 0.001
    10.times do
      AMQP::Connection.start(AMQP::Config.new(port: 5673)) do |conn|
        conn.channel
        s.client_connections.should eq(1)
        s.upstream_connections.should eq(1)
      end
    end
    s.client_connections.should eq(0)
    s.upstream_connections.should eq(1)
    s.close
  end
end
