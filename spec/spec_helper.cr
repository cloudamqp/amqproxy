require "spec"
require "../src/amqproxy/server"
require "../src/amqproxy/version"
require "amqp-client"

MAYBE_SUDO = ENV.has_key?("NO_SUDO") ? "" : "sudo "
