require "statsd"

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

    def initialize(statsd_host : String, statsd_port : Int32)
      @client = Statsd::Client.new statsd_host, statsd_port
    end

    def increment(metric_name, sample_rate = nil, tags = nil)
      @client.increment("#{PREFIX}.#{metric_name}", sample_rate, tags)
    end

    def gauge(metric_name, value, tags = nil)
      @client.gauge("#{PREFIX}.#{metric_name}", value, tags)
    end
  end
end
