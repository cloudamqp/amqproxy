require "spec"
require "../../src/amqproxy/options"

describe AMQProxy::Options do
  it "can be changed by with yielding a new options record with correct property values" do
    options = AMQProxy::Options.new

    options = options.with(
      listen_port: 34,
      http_port: 35,
      idle_connection_timeout: 36,
      term_timeout: 37,
      term_client_close_timeout: 38,
      log_level: ::Log::Severity::Trace,
      is_debug: true,
      ini_file: "the_init_file.config",
      listen_address: "listen.example.com",
      upstream: "upstream.example.com:39"
    )

    options.listen_address.should eq "listen.example.com"
    options.listen_port.should eq 34
    options.upstream.should eq "upstream.example.com:39"
    options.http_port.should eq 35
    options.idle_connection_timeout.should eq 36
    options.term_timeout.should eq 37
    options.term_client_close_timeout.should eq 38
    options.log_level.should eq ::Log::Severity::Trace
    options.is_debug.should eq true
    options.ini_file.should eq "the_init_file.config"
  end
end
