require "spec"
require "../src/amqproxy/server"
require "../src/amqproxy/version"
require "amqp-client"

MAYBE_SUDO = ENV["USER"]? == "root" ? "" : "sudo "
