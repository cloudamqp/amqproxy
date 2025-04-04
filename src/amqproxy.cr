require "./amqproxy/cli"
{% begin %}
  {%
    flags = [] of String
    flags << "-Dpreview_mt" if flag?(:preview_mt)
    flags << "-Dmt" if flag?(:mt)
    flags << "-Dexecution_context" if flag?(:execution_context)
    flags << "-Dtracing" if flag?(:tracing)
    flags << "--release" if flag?(:release)
    flags << "--static" if flag?(:static)
    flags << "--debug" if flag?(:debug)
  %}
  puts "Built with #{Crystal::VERSION} #{Crystal::BUILD_COMMIT} {{flags.join(" ").id}}"
{% end %}
AMQProxy::CLI.new.run(ARGV)
