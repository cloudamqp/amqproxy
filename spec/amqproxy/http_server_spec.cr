require "../spec_helper"
require "../../src/amqproxy/http_server"
require "http/client"

base_addr = "http://localhost:15673"

describe AMQProxy::HTTPServer do
  it "GET /healthz returns 200" do
    with_http_server do |http, amqproxy|
      response = HTTP::Client.get("#{base_addr}/healthz")
      response.status_code.should eq 200
    end
  end

  it "GET /metrics returns 200" do
    with_http_server do |http, amqproxy|
      response = HTTP::Client.get("#{base_addr}/metrics")
      response.status_code.should eq 200
    end
  end

  it "GET /metrics returns correct metrics" do
    with_http_server do |http, amqproxy, proxy_url|
      AMQP::Client.start(proxy_url) do |conn|
        ch = conn.channel
        response = HTTP::Client.get("#{base_addr}/metrics")
        response.body.split("\n").each do |line|
          if line.starts_with?("amqproxy_client_connections")
            line.should eq "amqproxy_client_connections 1"
          elsif line.starts_with?("amqproxy_upstream_connections")
            line.should eq "amqproxy_upstream_connections 1"
          end
        end
      end
    end
  end
end
