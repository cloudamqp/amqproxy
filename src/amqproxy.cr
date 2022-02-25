require "./amqproxy/version"
require "./amqproxy/server"
require "./amqproxy/metrics_client"
require "option_parser"
require "uri"

listen_address = ENV["LISTEN_ADDRESS"]? || "localhost"
listen_port = ENV["LISTEN_PORT"]? || 5673
log_level = Logger::INFO
idle_connection_timeout = 5
statsd_host = ""
statsd_port = 8125
p = OptionParser.parse do |parser|
  parser.banner = "Usage: amqproxy [options] [amqp upstream url]"
  parser.on("-l ADDRESS", "--listen=ADDRESS", "Address to listen on (default is localhost)") { |p| listen_address = p }
  parser.on("-p PORT", "--port=PORT", "Port to listen on (default: 5673)") { |p| listen_port = p.to_i }
  parser.on("-t IDLE_CONNECTION_TIMEOUT", "--idle-connection-timeout=SECONDS", "Maxiumum time in seconds an unused pooled connection stays open (default 5s)") do |p|
    idle_connection_timeout = p.to_i
  end
  parser.on("--statsd-host=STATSD_HOST", "StatsD host to send metrics to (default disabled)") { |p| statsd_host = p }
  parser.on("--statsd-port=STATSD_PORT", "StatsD port to send metrics to (default is 8125)") { |p| statsd_port = p.to_i }
  parser.on("-d", "--debug", "Verbose logging") { |d| log_level = Logger::DEBUG }
  parser.on("-h", "--help", "Show this help") { puts parser.to_s; exit 0 }
  parser.on("-v", "--version", "Display version") { puts AMQProxy::VERSION.to_s; exit 0 }
  parser.invalid_option { |arg| abort "Invalid argument: #{arg}" }
end

upstream = ARGV.shift? || ENV["AMQP_URL"]?
abort p.to_s if upstream.nil?

u = URI.parse upstream
abort "Invalid upstream URL" unless u.host
default_port =
  case u.scheme
  when "amqp" then 5672
  when "amqps" then 5671
  else abort "Not a valid upstream AMQP URL, should be on the format of amqps://hostname"
  end
port = u.port || default_port
tls = u.scheme == "amqps"

metrics_client = statsd_host.empty? ? AMQProxy::DummyMetricsClient.new : AMQProxy::StatsdClient.new(statsd_host, statsd_port)
server = AMQProxy::Server.new(u.host || "", port, tls, metrics_client, log_level, idle_connection_timeout)

shutdown = -> (s : Signal) do
  server.close
  exit 0
end
Signal::INT.trap &shutdown
Signal::TERM.trap &shutdown

server.listen(listen_address, listen_port.to_i)
