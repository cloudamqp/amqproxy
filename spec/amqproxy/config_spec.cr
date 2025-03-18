require "spec"
require "../../src/amqproxy/config"

describe AMQProxy::Config do
  it "loads defaults when no env vars are set" do
    previous_argv = ARGV.clone
    ARGV.clear

    config = AMQProxy::Config.load_with_cli(ARGV)

    config.listen_address.should eq "127.0.0.1"
    config.listen_port.should eq 5673

    # Restore ARGV
    ARGV.clear
    ARGV.concat(previous_argv)
  end

  it "reads from environment variables" do
    previous_argv = ARGV.clone
    ARGV.clear

    ENV["LISTEN_ADDRESS"] = "example.com"
    ENV["LISTEN_PORT"] = "5674"

    config = AMQProxy::Config.load_with_cli(ARGV)

    config.listen_address.should eq "example.com"
    config.listen_port.should eq 5674

    # Clean up
    ENV.delete("LISTEN_ADDRESS")
    ENV.delete("LISTEN_PORT")

    # Restore ARGV
    ARGV.clear
    ARGV.concat(previous_argv)
  end

  it "reads from command line arguments and overrules env vars" do
    previous_argv = ARGV.clone
    ARGV.clear

    ENV["LISTEN_ADDRESS"] = "example_env.com"
    ENV["LOG_LEVEL"] = "Error"
    ARGV.concat(["--listen=example_arg.com", "--log-level=Warn"])

    config = AMQProxy::Config.load_with_cli(ARGV)

    config.listen_address.should eq "example_arg.com"
    config.log_level.should eq ::Log::Severity::Warn

    # Clean Up
    ENV.delete("LISTEN_ADDRESS")

    # Restore ARGV
    ARGV.clear
    ARGV.concat(previous_argv)
  end

  it "reads from empty config file returning default configuration" do
    previous_argv = ARGV.clone
    ARGV.clear

    config = AMQProxy::Config.load_with_cli(ARGV, "/tmp/config_empty.ini")
    
    config.listen_address.should eq "localhost"
    
    # Restore ARGV
    ARGV.clear
    ARGV.concat(previous_argv)
  end

  it "reads without error when ini file is missing" do
    previous_argv = ARGV.clone
    ARGV.clear

    config = AMQProxy::Config.load_with_cli(ARGV, "/tmp/non_existing_file.ini")

    config.listen_address.should eq "localhost"

    # Restore ARGV
    ARGV.clear
    ARGV.concat(previous_argv)
  end
end
