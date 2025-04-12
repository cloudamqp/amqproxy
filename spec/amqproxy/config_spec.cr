require "spec"
require "../../src/amqproxy/config"

describe AMQProxy::Config do
  it "loads defaults when no ini file, env vars or options are available" do
    previous_argv = ARGV.clone
    ARGV.clear

    ARGV.concat([
      "--config=/tmp/non_existing_file.ini",
    ])

    config = AMQProxy::Config.load_with_cli(ARGV)

    config.listen_address.should eq "localhost"
    config.listen_port.should eq 5673
    config.http_port.should eq 15673
    config.log_level.should eq ::Log::Severity::Info
    config.idle_connection_timeout.should eq 5
    config.term_timeout.should eq -1
    config.term_client_close_timeout.should eq 0
    config.upstream.should eq nil

    # Restore ARGV
    ARGV.clear
    ARGV.concat(previous_argv)
  end

  it "reads from empty config file returning default configuration" do
    previous_argv = ARGV.clone
    ARGV.clear

    ARGV.concat(["--config=/tmp/config_empty.ini"])

    config = AMQProxy::Config.load_with_cli(ARGV)

    config.listen_address.should eq "localhost"
    config.listen_port.should eq 5673
    config.http_port.should eq 15673
    config.log_level.should eq ::Log::Severity::Info
    config.idle_connection_timeout.should eq 5
    config.term_timeout.should eq -1
    config.term_client_close_timeout.should eq 0
    config.upstream.should eq nil

    # Restore ARGV
    ARGV.clear
    ARGV.concat(previous_argv)
  end

  it "reads from environment variables and overrules ini file values" do
    previous_argv = ARGV.clone
    ARGV.clear

    ENV["LISTEN_ADDRESS"] = "example.com"
    ENV["LISTEN_PORT"] = "5674"
    ENV["HTTP_PORT"] = "15674"
    ENV["LOG_LEVEL"] = "Error"
    ENV["IDLE_CONNECTION_TIMEOUT"] = "12"
    ENV["TERM_TIMEOUT"] = "13"
    ENV["TERM_CLIENT_CLOSE_TIMEOUT"] = "14"
    ENV["UPSTREAM"] = "amqp://localhost:5674"

    config = AMQProxy::Config.load_with_cli(ARGV)

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

    # Restore ARGV
    ARGV.clear
    ARGV.concat(previous_argv)
  end

  it "reads from command line arguments and overrules env vars" do
    previous_argv = ARGV.clone
    ARGV.clear

    ENV["LISTEN_ADDRESS"] = "example.com"
    ENV["LISTEN_PORT"] = "5674"
    ENV["HTTP_PORT"] = "15674"
    ENV["LOG_LEVEL"] = "Error"
    ENV["IDLE_CONNECTION_TIMEOUT"] = "12"
    ENV["TERM_TIMEOUT"] = "13"
    ENV["TERM_CLIENT_CLOSE_TIMEOUT"] = "14"
    ENV["UPSTREAM"] = "amqp://localhost:5674"

    ARGV.concat([
      "--listen=example_arg.com",
      "--port=5675",
      "--http-port=15675",
      "--log-level=Warn",
      "--idle-connection-timeout=15",
      "--term-timeout=16",
      "--term-client-close-timeout=17",
      "amqp://localhost:5679",
    ])

    config = AMQProxy::Config.load_with_cli(ARGV)

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

    # Restore ARGV
    ARGV.clear
    ARGV.concat(previous_argv)
  end

  it "sets log level to debug when debug flag is present" do
    previous_argv = ARGV.clone
    ARGV.clear

    ARGV.concat([
      "--listen=example_arg.com",
      "--port=5675",
      "--http-port=15675",
      "--log-level=Warn",
      "--idle-connection-timeout=15",
      "--term-timeout=16",
      "--term-client-close-timeout=17",
      "--debug",
      "amqp://localhost:5679",
    ])

    config = AMQProxy::Config.load_with_cli(ARGV)

    config.listen_address.should eq "example_arg.com"
    config.log_level.should eq ::Log::Severity::Debug
    config.listen_port.should eq 5675
    config.http_port.should eq 15675
    config.idle_connection_timeout.should eq 15
    config.term_timeout.should eq 16
    config.term_client_close_timeout.should eq 17
    config.upstream.should eq "amqp://localhost:5679"

    # Restore ARGV
    ARGV.clear
    ARGV.concat(previous_argv)
  end

  it "keeps the log level to trace when debug flag is present" do
    previous_argv = ARGV.clone
    ARGV.clear

    ARGV.concat([
      "--log-level=Trace",
      "--debug",
    ])

    config = AMQProxy::Config.load_with_cli(ARGV)

    config.log_level.should eq ::Log::Severity::Trace

    # Restore ARGV
    ARGV.clear
    ARGV.concat(previous_argv)
  end
end
