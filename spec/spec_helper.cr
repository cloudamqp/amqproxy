require "spec"
require "../src/amqproxy/server"
require "../src/amqproxy/version"
require "../src/amqproxy/metrics_client"
require "amqp-client"

MAYBE_SUDO = ENV.has_key?("NO_SUDO") ? "" : "sudo "
