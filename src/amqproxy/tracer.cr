module AMQProxy
  abstract class Tracer
    abstract def trace(operation_name : String, resource : String? = nil, tags = NamedTuple.new, &)
    abstract def close
  end
end
