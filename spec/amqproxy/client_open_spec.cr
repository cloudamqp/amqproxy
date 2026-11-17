require "../spec_helper"

describe AMQProxy::Client do
  it "refuses the client's connect when the upstream refuses its credentials" do
    with_server do |server, proxy_url|
      uri = URI.parse(proxy_url)
      uri.user = "guest"
      uri.password = "wrong password"
      expect_raises(Exception, /ACCESS_REFUSED/) do
        AMQP::Client.new(uri.to_s).connect
      end
      wait_until { server.client_connections.zero? }.should be_true
    end
  end
end
