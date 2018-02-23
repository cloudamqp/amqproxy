require "./amqproxy/version"
require "./amqproxy/server"
require "option_parser"
require "uri"

listen_address = "localhost"
listen_port = 5673
p = OptionParser.parse! do |parser|
  parser.banner = "Usage: amqproxy [options] [amqp upstream url]"
  parser.on("-l ADDRESS", "--listen=ADDRESS", "Address to listen on (default: localhost)") { |p| listen_address = p }
  parser.on("-p PORT", "--port=PORT", "Port to listen on (default: 5673)") { |p| listen_port = p.to_i }
  parser.on("-h", "--help", "Show this help") { abort parser.to_s }
  parser.invalid_option { |arg| abort "Invalid argument: #{arg}" }
end

upstream = ARGV.shift?
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

server = AMQProxy::Server.new(u.host || "", port, tls)
shutdown = -> (s : Signal) do
  server.close
  exit 0
end
Signal::INT.trap &shutdown
Signal::TERM.trap &shutdown

server.listen(listen_address, listen_port)
