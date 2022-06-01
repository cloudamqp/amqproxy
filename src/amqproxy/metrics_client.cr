require "statsd"
require "socket"

module AMQProxy
  abstract class MetricsClient
    abstract def increment(metric_name, sample_rate = nil, tags = nil)
    abstract def gauge(metric_name, value, tags = nil)
  end

  class DummyMetricsClient < MetricsClient
    def increment(metric_name, sample_rate = nil, tags = nil)
    end

    def gauge(metric_name, value, tags = nil)
    end
  end

  class StatsdClient < MetricsClient
    PREFIX = "amqproxy"

    def initialize(log : Logger, statsd_host : String, statsd_port : Int32)
      host = resolve(statsd_host, statsd_port)
      @client = Statsd::Client.new(host, statsd_port)
      log.info "Statsd sink configured at: #{statsd_host}:#{statsd_port}"
    end

    def increment(metric_name, sample_rate = nil, tags = nil)
      @client.increment("#{PREFIX}.#{metric_name}", sample_rate, tags)
    end

    def gauge(metric_name, value, tags = nil)
      @client.gauge("#{PREFIX}.#{metric_name}", value, tags)
    end

    private def resolve(host : String, port : Int32)
      addr = ""
      addr_info = Socket::Addrinfo.resolve(host, port, Socket::Family::INET, Socket::Type::STREAM, Socket::Protocol::IP)
      addr_info.each { |a|
        addr = a.ip_address.to_s.rchop(":#{port}")
        break
      }
      addr
    end
  end
end
