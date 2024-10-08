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
