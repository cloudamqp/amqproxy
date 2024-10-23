require "log"
require "spec"
require "uri"
require "../src/amqproxy/server"
require "../src/amqproxy/version"
require "amqp-client"

Log.setup_from_env(default_level: :error)

MAYBE_SUDO = (ENV.has_key?("NO_SUDO") || `id -u` == "0\n") ? "" : "sudo "

UPSTREAM_URL = begin
  URI.parse ENV.fetch("UPSTREAM_URL", "amqp://127.0.0.1:5672?idle_connection_timeout=5")
rescue e : URI::Error
  puts "Invalid UPSTREAM_URL: #{e}"
  exit 1
end

def with_server(idle_connection_timeout = 5, &)
  server = AMQProxy::Server.new(UPSTREAM_URL)
  tcp_server = TCPServer.new("127.0.0.1", 0)
  amqp_url = "amqp://#{tcp_server.local_address}"
  spawn { server.listen(tcp_server) }
  yield server, amqp_url
ensure
  if s = server
    s.stop_accepting_clients
  end
end

def with_http_server(idle_connection_timeout = 5, &)
  with_server do |server, amqp_url|
    http_server = AMQProxy::HTTPServer.new(server, "127.0.0.1", 15673)
    begin
      yield http_server, server, amqp_url
    ensure
      http_server.close
    end
  end
end

def verify_running_amqp!
  tls = UPSTREAM_URL.scheme == "amqps"
  host = UPSTREAM_URL.host || "127.0.0.1"
  port = UPSTREAM_URL.port || 5762
  port = 5671 if tls && UPSTREAM_URL.port.nil?
  TCPSocket.new(host, port, connect_timeout: 3.seconds).close
rescue Socket::ConnectError
  STDERR.puts "[ERROR] Specs require a running rabbitmq server on #{host}:#{port}"
  exit 1
end

Spec.before_suite do
  verify_running_amqp!
end
