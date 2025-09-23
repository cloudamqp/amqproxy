require "./tracer"

module AMQProxy
  class NilTracer < Tracer
    def trace(operation_name : String, resource : String? = nil, tags = NamedTuple.new, &)
      yield
    end

    def close
    end
  end
end
