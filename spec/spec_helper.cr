require "spec"
require "../src/amqproxy/server"
require "../src/amqproxy/version"
require "amqp-client"

MAYBE_SUDO = (ENV.has_key?("NO_SUDO") || `id -u` == "0\n") ? "" : "sudo "

# Spec timeout borrowed from Crystal project:
# https://github.com/crystal-lang/crystal/blob/1.10.1/spec/support/mt_abort_timeout.cr

private SPEC_TIMEOUT = 15.seconds

Spec.around_each do |example|
  done = Channel(Exception?).new

  spawn(same_thread: true) do
    begin
      example.run
    rescue e
      done.send(e)
    else
      done.send(nil)
    end
  end

  timeout = SPEC_TIMEOUT

  select
  when res = done.receive
    raise res if res
  when timeout(timeout)
    _it = example.example
    ex = Spec::AssertionFailed.new("spec timed out after #{timeout}", _it.file, _it.line)
    _it.parent.report(:fail, _it.description, _it.file, _it.line, timeout, ex)
  end
end
