require "./amqproxy/cli"

# {% if flag?(:preview_mt) %}
#  {% unless parse_type("Fiber::ExecutionContext").resolve? %}
#    {% if read_file("shard.yml").includes? "execution_context" %}
#      {% puts "using execution_context shard" %}
#      require "execution_context"
#    {% end %}
#  {% end %}
# {% end %}
#
{% begin %}
  {%
    flags = [] of String
    flags << "-Dpreview_mt" if flag?(:preview_mt)
    flags << "-Dmt" if flag?(:mt)
    flags << "-Dexecution_context" if flag?(:execution_context)
    flags << "-Drelease" if flag?(:release)
  %}

  puts "Built with #{Crystal::VERSION} #{Crystal::BUILD_COMMIT} {{flags.join(" ").id}}"

  {% end %}
AMQProxy::CLI.new.run(ARGV)
