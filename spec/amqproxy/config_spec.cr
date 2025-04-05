require "spec"
require "../../src/amqproxy/config"
require "../../src/amqproxy/options"

describe AMQProxy::Config do
  it "loads defaults when no ini file, env vars or options are available" do
    options = AMQProxy::Options.new
    options.ini_file = "/tmp/non_existing_file.ini"

    config = AMQProxy::Config.load_with_cli(options)

    config.listen_address.should eq "localhost"
    config.listen_port.should eq 5673
    config.http_port.should eq 15673
    config.log_level.should eq ::Log::Severity::Info
    config.idle_connection_timeout.should eq 5
    config.term_timeout.should eq -1
    config.term_client_close_timeout.should eq 0
    config.upstream.should eq nil
  end

  it "reads from empty config file returning default configuration" do
    options = AMQProxy::Options.new
    options.ini_file = "/tmp/config_empty.ini"

    config = AMQProxy::Config.load_with_cli(options)
    
    config.listen_address.should eq "localhost"
    config.listen_port.should eq 5673
    config.http_port.should eq 15673
    config.log_level.should eq ::Log::Severity::Info
    config.idle_connection_timeout.should eq 5
    config.term_timeout.should eq -1
    config.term_client_close_timeout.should eq 0
    config.upstream.should eq nil
  end

  it "reads from environment variables and use AMPQ_URL over UPSTREAM variable" do
    options = AMQProxy::Options.new

    ENV["AMQP_URL"] = "amqp://localhost:5673"
    ENV["UPSTREAM"] = "amqp://localhost:5674"
    
    config = AMQProxy::Config.load_with_cli(options)

    config.upstream.should eq "amqp://localhost:5673"

    # Clean up
    ENV.delete("AMQP_URL")
    ENV.delete("UPSTREAM")
  end

  it "reads from environment variables and overrules ini file values" do
    options = AMQProxy::Options.new

    ENV["LISTEN_ADDRESS"] = "example.com"
    ENV["LISTEN_PORT"] = "5674"
    ENV["HTTP_PORT"] = "15674"
    ENV["LOG_LEVEL"] = "Error"
    ENV["IDLE_CONNECTION_TIMEOUT"] = "12"
    ENV["TERM_TIMEOUT"] = "13"
    ENV["TERM_CLIENT_CLOSE_TIMEOUT"] = "14"
    ENV["UPSTREAM"] = "amqp://localhost:5674"
    
    config = AMQProxy::Config.load_with_cli(options)

    config.listen_address.should eq "example.com"
    config.listen_port.should eq 5674
    config.http_port.should eq 15674
    config.log_level.should eq ::Log::Severity::Error
    config.idle_connection_timeout.should eq 12
    config.term_timeout.should eq 13
    config.term_client_close_timeout.should eq 14
    config.upstream.should eq "amqp://localhost:5674"

    # Clean up
    ENV.delete("LISTEN_ADDRESS")
    ENV.delete("LISTEN_PORT")
    ENV.delete("HTTP_PORT")
    ENV.delete("LOG_LEVEL")
    ENV.delete("IDLE_CONNECTION_TIMEOUT")
    ENV.delete("TERM_TIMEOUT")
    ENV.delete("TERM_CLIENT_CLOSE_TIMEOUT")
    ENV.delete("UPSTREAM")
  end

  it "reads from command line arguments and overrules env vars" do
    ENV["LISTEN_ADDRESS"] = "example.com"
    ENV["LISTEN_PORT"] = "5674"
    ENV["HTTP_PORT"] = "15674"
    ENV["LOG_LEVEL"] = "Error"
    ENV["IDLE_CONNECTION_TIMEOUT"] = "12"
    ENV["TERM_TIMEOUT"] = "13"
    ENV["TERM_CLIENT_CLOSE_TIMEOUT"] = "14"
    ENV["UPSTREAM"] = "amqp://localhost:5674"

    options = AMQProxy::Options.new
    options.listen_address = "example_arg.com"
    options.listen_port = 5675
    options.http_port = 15675
    options.log_level = ::Log::Severity::Warn
    options.idle_connection_timeout = 15
    options.term_timeout = 16
    options.term_client_close_timeout = 17
    options.upstream = "amqp://localhost:5679"

    config = AMQProxy::Config.load_with_cli(options)

    config.listen_address.should eq "example_arg.com"
    config.log_level.should eq ::Log::Severity::Warn
    config.listen_port.should eq 5675
    config.http_port.should eq 15675
    config.idle_connection_timeout.should eq 15
    config.term_timeout.should eq 16
    config.term_client_close_timeout.should eq 17
    config.upstream.should eq "amqp://localhost:5679"

    # Clean Up
    ENV.delete("LISTEN_ADDRESS")
    ENV.delete("LISTEN_PORT")
    ENV.delete("HTTP_PORT")
    ENV.delete("LOG_LEVEL")
    ENV.delete("IDLE_CONNECTION_TIMEOUT")
    ENV.delete("TERM_TIMEOUT")
    ENV.delete("TERM_CLIENT_CLOSE_TIMEOUT")
    ENV.delete("UPSTREAM")
  end

  it "sets log level to debug when debug flag is present" do
    options = AMQProxy::Options.new
    options.listen_address = "example_arg.com"
    options.listen_port = 5675
    options.http_port = 15675
    options.log_level = ::Log::Severity::Warn
    options.idle_connection_timeout = 15
    options.term_timeout = 16
    options.term_client_close_timeout = 17
    options.is_debug = true
    options.upstream = "amqp://localhost:5679"

    config = AMQProxy::Config.load_with_cli(options)

    config.listen_address.should eq "example_arg.com"
    config.log_level.should eq ::Log::Severity::Debug
    config.listen_port.should eq 5675
    config.http_port.should eq 15675
    config.idle_connection_timeout.should eq 15
    config.term_timeout.should eq 16
    config.term_client_close_timeout.should eq 17
    config.upstream.should eq "amqp://localhost:5679"
  end

  it "keeps the log level to trace when debug flag is present" do
    options = AMQProxy::Options.new
    options.listen_address = "example_arg.com"
    options.listen_port = 5675
    options.http_port = 15675
    options.log_level = ::Log::Severity::Trace
    options.idle_connection_timeout = 15
    options.term_timeout = 16
    options.term_client_close_timeout = 17
    options.is_debug = true
    options.upstream = "amqp://localhost:5679"

    config = AMQProxy::Config.load_with_cli(options)

    config.log_level.should eq ::Log::Severity::Trace
  end

  it "reads default ini file when ini file path is null" do
    options = AMQProxy::Options.new
    
    config = AMQProxy::Config.load_with_cli(options)

    config.listen_address.should eq "127.0.0.2"
    config.listen_port.should eq 5678
    config.http_port.should eq 15678
    config.log_level.should eq ::Log::Severity::Debug
    config.idle_connection_timeout.should eq 55
    config.term_timeout.should eq 56
    config.term_client_close_timeout.should eq 57
    config.upstream.should eq "amqp://localhost:5678"
  end
end
