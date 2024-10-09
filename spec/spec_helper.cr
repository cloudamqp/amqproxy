require "spec"
require "../src/amqproxy/server"
require "../src/amqproxy/version"
require "amqp-client"

MAYBE_SUDO = (ENV.has_key?("NO_SUDO") || `id -u` == "0\n") ? "" : "sudo "

def with_server(idle_connection_timeout = 5, &)
  server = AMQProxy::Server.new("127.0.0.1", 5672, false)
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
  TCPSocket.new("127.0.0.1", 5672, connect_timeout: 3.seconds).close
rescue Socket::ConnectError
  STDERR.puts "[ERROR] Specs require a running amqp server on 127.0.0.1:5672"
  exit 1
end

Spec.before_suite do
  verify_running_amqp!
end
