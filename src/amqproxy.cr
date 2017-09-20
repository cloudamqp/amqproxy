require "./amqproxy/version"
require "./amqproxy/server"
require "option_parser"
require "file"
require "ini"

config = {
  "server" => {
    "upstream" => "amqp://localhost:5672",
    "maxConnections" => "5000",
  },
  "listen" => {
    "address" => "localhost",
    "port" => "5673",
  }
} of String => Hash(String, String)

OptionParser.parse! do |parser|
  parser.banner = "Usage: #{File.basename PROGRAM_NAME} [arguments]"
  parser.on("-c CONFIG_FILE", "--config=CONFIG_FILE", "Config file to read") do |c|
    abort "Config file could not be read" unless File.file? c
    config.merge!(INI.parse(File.read(c)))
  end
  parser.on("-u AMQP_URL", "--upstream=AMQP_URL", "URL to upstream server") do |u|
    url = u
  end
  parser.on("-p PORT", "--port=PORT", "Port to listen on") { |p| config["server"]["port"] = p }
  parser.on("-P PREFETCH", "--default-prefetch=PREFETCH", "Default prefetch for channels") { |p| config["server"]["defaultPrefetch"] = p }
  parser.on("-C MAXCONNECTIONS", "--max-connections=MAXCONNECTIONS", "Max connections opened to upstream") { |p| config["server"]["maxConnections"] = p }
  parser.on("-h", "--help", "Show this help") { puts parser; exit 1 }
  parser.invalid_option { |arg| abort "Invalid argument: #{arg}" }
end

server = AMQProxy::Server.new(config["server"])
if config["listen"]["certificateChain"]?
  server.listen_tls(config["listen"]["address"], config["listen"]["port"].to_i,
                    config["listen"]["certificateChain"], config["listen"]["privateKey"])
else
  server.listen(config["listen"]["address"], config["listen"]["port"].to_i)
end
