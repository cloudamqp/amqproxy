require "http/client"
require "json"
require "log"
require "./tracer"

module AMQProxy
  class DatadogTracer < Tracer
    Log = ::Log.for(self)

    @service_name : String
    @env : String
    @version : String
    @agent_host : String
    @agent_port : Int32
    @http_client : HTTP::Client

    def initialize(service_name = "amqproxy", env = "production", version = VERSION, agent_host = "localhost", agent_port = 8126)
      @service_name = service_name
      @env = env
      @version = version
      @agent_host = agent_host
      @agent_port = agent_port
      @http_client = HTTP::Client.new(agent_host, agent_port)
      @http_client.connect_timeout = 1.second
      @http_client.read_timeout = 1.second
    end

    def trace(operation_name : String, resource : String? = nil, tags = NamedTuple.new, &)
      trace_id = Random.rand(UInt64::MAX)
      span_id = Random.rand(UInt64::MAX)
      start_time = Time.monotonic
      start_time_ns = Time.utc.to_unix_ns.to_i64

      begin
        result = yield
        duration = (Time.monotonic - start_time).total_nanoseconds.to_i64
        send_span(trace_id, span_id, operation_name, resource, start_time_ns, duration, tags, error: false)
        result
      rescue ex
        duration = (Time.monotonic - start_time).total_nanoseconds.to_i64
        error_tags = tags.merge(error_type: ex.class.name, error_message: ex.message)
        send_span(trace_id, span_id, operation_name, resource, start_time_ns, duration, error_tags, error: true)
        raise ex
      end
    end

    private def send_span(trace_id : UInt64, span_id : UInt64, operation_name : String, resource : String?, start_time : Int64, duration : Int64, tags, error : Bool)
      meta_tags = tags.merge({
        env:      @env,
        version:  @version,
        language: "crystal",
      })

      span = {
        trace_id: trace_id,
        span_id:  span_id,
        name:     operation_name,
        resource: resource || operation_name,
        service:  @service_name,
        type:     "custom",
        start:    start_time,
        duration: duration,
        error:    error ? 1 : 0,
        meta:     meta_tags,
      }

      payload = JSON.build do |json|
        json.array do
          json.array do
            span.to_json(json)
          end
        end
      end

      spawn do
        begin
          response = @http_client.put("/v0.4/traces",
            headers: HTTP::Headers{"Content-Type" => "application/json"},
            body: payload
          )

          unless response.success?
            Log.debug { "Failed to send trace to Datadog: #{response.status_code} #{response.body}" }
          end
        rescue ex
          Log.debug { "Error sending trace to Datadog: #{ex.message}" }
        end
      end
    end

    def close
      @http_client.close
    end
  end
end
