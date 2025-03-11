require "./amqproxy/cli"

{% if flag?(:preview_mt) %}
  {% unless parse_type("Fiber::ExecutionContext").resolve? %}
    {% if read_file("shard.yml").includes? "execution_context" %}
      {% puts "using execution_context shard" %}
      require "execution_context"
    {% end %}
  {% end %}
{% end %}

AMQProxy::CLI.new.run(ARGV)
