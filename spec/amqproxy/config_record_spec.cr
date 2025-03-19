require "spec"
require "../../src/amqproxy/config_record"

describe AMQProxy::Configuration do
  it "loads defaults when no ini file, env vars or options are available" do
    previous_argv = ARGV.clone
    ARGV.clear

    config = AMQProxy::Configuration.load_with_cli(ARGV, "/tmp/non_existing_file.ini")

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

  it "reads from environment variables and overwrites ini file values" do
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
    
    config = AMQProxy::Configuration.load_with_cli(ARGV)

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

    ARGV.concat(["--listen=example_arg.com", "--port=5675", "--http-port=15675", "--log-level=Warn", "--idle-connection-timeout=15", "--term-timeout=16", "--term-client-close-timeout=17"])

    config = AMQProxy::Configuration.load_with_cli(ARGV)

    config.listen_address.should eq "example_arg.com"
    config.log_level.should eq ::Log::Severity::Warn
    config.listen_port.should eq 5675
    config.http_port.should eq 15675
    config.idle_connection_timeout.should eq 15
    config.term_timeout.should eq 16
    config.term_client_close_timeout.should eq 17

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

  it "reads from empty config file returning default configuration" do
    previous_argv = ARGV.clone
    ARGV.clear

    config = AMQProxy::Configuration.load_with_cli(ARGV, "/tmp/config_empty.ini")
    
    config.listen_address.should eq "localhost"
    
    # Restore ARGV
    ARGV.clear
    ARGV.concat(previous_argv)
  end

  it "reads init file without error" do
    previous_argv = ARGV.clone
    ARGV.clear

    config = AMQProxy::Configuration.load_with_cli(ARGV, "/tmp/config.ini")

    config.listen_address.should eq "127.0.0.2"
    config.listen_port.should eq 5678
    config.http_port.should eq 15678
    config.log_level.should eq ::Log::Severity::Debug
    config.idle_connection_timeout.should eq 55
    config.term_timeout.should eq 56
    config.term_client_close_timeout.should eq 57
    config.upstream.should eq "amqp://localhost:5678"

    # Restore ARGV
    ARGV.clear
    ARGV.concat(previous_argv)
  end
end
