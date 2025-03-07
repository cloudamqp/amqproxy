require "./amqproxy/cli"

{% if flag?(:preview_mt) && !parse_type("ExecutionContext").resolve? %}
  {% if read_file("shard.yml").includes? "execution_context" %}
    {% puts "using execution_context shard" %}
    require "execution_context"
  {% end %}
{% end %}

AMQProxy::CLI.new.run(ARGV)
