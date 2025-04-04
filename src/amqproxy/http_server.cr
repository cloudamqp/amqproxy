require "log"
require "./prometheus_writer"
require "http/server"

module AMQProxy
  class HTTPServer
    Log = ::Log.for(self)

    def initialize(amqproxy : Server, address : String, port : Int32)
      @amqproxy = amqproxy
      @address = address
      @port = port
      @http = HTTP::Server.new do |context|
        case context.request.resource
        when "/metrics"
          metrics(context)
        when "/healthz"
          context.response.content_type = "text/plain"
          context.response.print "OK"
        else
          context.response.respond_with_status(::HTTP::Status::NOT_FOUND)
        end
      end
      bind_tcp
      Log.info { "HTTP server listening on #{@address}:#{@port}" }
    end

    def bind_tcp
      addr = @http.bind_tcp @address, @port
      Log.info { "Bound to #{addr}" }
    end

    def listen
      @http.listen
    end

    def metrics(context)
      writer = PrometheusWriter.new(context.response, "amqproxy")
      writer.write({name:   "identity_info",
                    type:   "gauge",
                    value:  1,
                    help:   "System information",
                    labels: {
                      "#{writer.prefix}_version"  => AMQProxy::VERSION,
                      "#{writer.prefix}_hostname" => System.hostname,
                    }})
      writer.write({name:  "client_connections",
                    value: @amqproxy.client_connections,
                    type:  "gauge",
                    help:  "Number of client connections"})
      writer.write({name:  "upstream_connections",
                    value: @amqproxy.upstream_connections,
                    type:  "gauge",
                    help:  "Number of upstream connections"})

      context.response.status = ::HTTP::Status::OK
    end

    def close
      @http.try &.close
    end
  end
end
