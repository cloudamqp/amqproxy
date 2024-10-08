class PrometheusWriter
  alias MetricValue = UInt16 | Int32 | UInt32 | UInt64 | Int64 | Float64
  alias MetricLabels = Hash(String, String) |
                       NamedTuple(name: String) |
                       NamedTuple(channel: String) |
                       NamedTuple(id: String) |
                       NamedTuple(queue: String, vhost: String)
  alias Metric = NamedTuple(name: String, value: MetricValue) |
                 NamedTuple(name: String, value: MetricValue, labels: MetricLabels) |
                 NamedTuple(name: String, value: MetricValue, help: String) |
                 NamedTuple(name: String, value: MetricValue, type: String, help: String) |
                 NamedTuple(name: String, value: MetricValue, help: String, labels: MetricLabels) |
                 NamedTuple(name: String, value: MetricValue, type: String, help: String, labels: MetricLabels)

  getter prefix

  def initialize(@io : IO, @prefix : String)
  end

  private def write_labels(io, labels)
    first = true
    io << "{"
    labels.each do |k, v|
      io << ", " unless first
      io << k << "=\"" << v << "\""
      first = false
    end
    io << "}"
  end

  def write(m : Metric)
    return if m[:value].nil?
    io = @io
    name = "#{@prefix}_#{m[:name]}"
    if t = m[:type]?
      io << "# TYPE " << name << " " << t << "\n"
    end
    if h = m[:help]?
      io << "# HELP " << name << " " << h << "\n"
    end
    io << name
    if l = m[:labels]?
      write_labels(io, l)
    end
    io << " " << m[:value] << "\n"
  end
end
