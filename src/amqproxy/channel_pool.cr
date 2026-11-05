require "openssl"
require "log"
require "./records"
require "./upstream"

module AMQProxy
  class ChannelPool
    # An upstream connection that may still be connecting. Channels waiting
    # for it count as pending, so that it isn't given more than it can open.
    class PooledUpstream
      @lock = Mutex.new
      @pending = 0
      @upstream : Upstream?
      @error : Upstream::Error?
      @ready = Channel(Nil).new # closed when connected or failed

      # *channel_max* applies until the server has negotiated its own
      def initialize(@channel_max : UInt16)
      end

      # Counts a pending channel, unless the upstream is full or unusable
      def reserve? : Bool
        @lock.synchronize do
          return false if full?
          @pending += 1
          true
        end
      end

      private def full? : Bool
        return true if @error
        if upstream = @upstream
          upstream.closed? || upstream.channels + @pending >= upstream.channel_max
        else
          @pending >= @channel_max
        end
      end

      # Opens a channel reserved with `#reserve?`
      def open_channel(downstream_channel : DownstreamChannel, deadline : Time::Instant) : UpstreamChannel
        upstream = begin
          wait_for_connection(deadline)
        rescue ex
          @lock.synchronize { @pending -= 1 }
          raise ex
        end
        upstream_channel = @lock.synchronize do
          @pending -= 1 # counted by the upstream from here
          upstream.create_channel(downstream_channel)
        end
        upstream.open_channel(upstream_channel, deadline - Time.instant)
        upstream_channel
      end

      private def wait_for_connection(deadline : Time::Instant) : Upstream
        select
        when @ready.receive?
        when timeout(deadline - Time.instant)
          raise Upstream::Error.new "Timeout connecting to upstream"
        end
        @lock.synchronize do
          @upstream || raise(@error || Upstream::Error.new("Not connected to upstream"))
        end
      end

      def connected(upstream : Upstream) : Nil
        @lock.synchronize { @upstream = upstream }
        @ready.close
      end

      def failed(ex : Exception) : Nil
        @lock.synchronize do
          @error = ex.is_a?(Upstream::Error) ? ex : Upstream::Error.new(ex.message, cause: ex)
        end
        @ready.close
      end

      def connected? : Bool
        @lock.synchronize { !@upstream.nil? }
      end

      def closed? : Bool
        @lock.synchronize { @upstream.try(&.closed?) || false }
      end

      # Connected, without any open or pending channels
      def idle? : Bool
        @lock.synchronize do
          if upstream = @upstream
            upstream.channels.zero? && @pending.zero?
          else
            false
          end
        end
      end

      def close(reason : String) : Nil
        @lock.synchronize { @upstream }.try &.close(reason)
      end
    end

    Log = ::Log.for(self)

    # How long `#get` waits for a channel, including connecting to upstream
    OPEN_CHANNEL_TIMEOUT = 10.seconds

    @lock = Mutex.new
    @upstreams = Deque(PooledUpstream).new

    def initialize(@host : String, @port : Int32, @tls_ctx : OpenSSL::SSL::Context::Client?, @credentials : Credentials, @idle_connection_timeout : Int32, @max_upstream_channels : UInt16,
                   @open_channel_timeout : Time::Span = OPEN_CHANNEL_TIMEOUT)
      spawn shrink_pool_loop, name: "shrink pool loop"
    end

    def get(downstream_channel : DownstreamChannel) : UpstreamChannel
      deadline = Time.instant + @open_channel_timeout
      loop do
        pooled = @lock.synchronize { @upstreams.find(&.reserve?) || add_upstream.tap(&.reserve?) }
        return pooled.open_channel(downstream_channel, deadline)
      rescue Upstream::ChannelMaxReached
        # the server negotiated a lower channel_max than we reserved for
      end
    end

    # Must be called with the lock held
    private def add_upstream : PooledUpstream
      channel_max = @max_upstream_channels.zero? ? UInt16::MAX : @max_upstream_channels
      pooled = PooledUpstream.new(channel_max)
      @upstreams.unshift pooled
      spawn connect(pooled), name: "ChannelPool#connect"
      pooled
    end

    private def connect(pooled : PooledUpstream) : Nil
      upstream = begin
        Upstream.new(@host, @port, @tls_ctx, @credentials, @max_upstream_channels, @open_channel_timeout)
      rescue ex
        pooled.failed(ex)
        return
      end
      Log.info { "Adding upstream connection" }
      pooled.connected(upstream)
      upstream.read_loop
    ensure
      @lock.synchronize { @upstreams.delete pooled }
    end

    def connections
      @lock.synchronize { @upstreams.count(&.connected?) }
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
            if u.idle?
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
