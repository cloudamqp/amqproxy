require "openssl"
require "log"
require "./records"
require "./upstream"

module AMQProxy
  class ChannelPool
    Log = ::Log.for(self)
    @lock = Mutex.new
    @upstreams = Deque(Upstream).new

    def initialize(@host : String, @port : Int32, @tls_ctx : OpenSSL::SSL::Context::Client?, @credentials : Credentials, @idle_connection_timeout : Int32)
      spawn shrink_pool_loop, name: "shrink pool loop"
    end

    def get(downstream_channel : DownstreamChannel) : UpstreamChannel
      at_channel_max = 0
      @lock.synchronize do
        loop do
          if upstream = @upstreams.shift?
            next if upstream.closed?
            begin
              upstream_channel = upstream.open_channel_for(downstream_channel)
              @upstreams.unshift(upstream)
              return upstream_channel
            rescue Upstream::ChannelMaxReached
              @upstreams.push(upstream)
              at_channel_max += 1
              add_upstream if at_channel_max == @upstreams.size
            end
          else
            add_upstream
          end
        end
      end
    end

    private def add_upstream
      upstream = Upstream.new(@host, @port, @tls_ctx, @credentials)
      Log.info { "Adding upstream connection" }
      @upstreams.unshift upstream
      spawn(name: "Upstream#read_loop") do
        begin
          upstream.read_loop
        ensure
          @upstreams.delete upstream
        end
      end
    rescue ex : IO::Error
      raise Upstream::Error.new ex.message, cause: ex
    end

    def connections
      @upstreams.size
    end

    def close
      Log.info { "Closing all upstream connections" }
      @lock.synchronize do
        while u = @upstreams.shift?
          begin
            u.close "AMQProxy shutdown"
          rescue ex
            Log.error { "Problem closing upstream: #{ex.inspect}" }
          end
        end
      end
    end

    private def shrink_pool_loop
      loop do
        sleep @idle_connection_timeout.seconds
        @lock.synchronize do
          (@upstreams.size - 1).times do # leave at least one connection
            u = @upstreams.pop
            if u.channels.zero?
              begin
                u.close "Pooled connection closed due to inactivity"
              rescue ex
                Log.error { "Problem closing upstream: #{ex.inspect}" }
              end
            elsif u.closed?
              Log.error { "Removing closed upstream connection from pool" }
            else
              @upstreams.unshift u
            end
          end
        end
      end
    end
  end
end
