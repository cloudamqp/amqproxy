require "openssl"
require "log"
require "./records"
require "./upstream"

module AMQProxy
  class ChannelPool
    # An upstream connection that may still be connecting. Channels waiting
    # for it count as pending, so that it isn't given more than it can open.
    class PooledUpstream
      @@last_id = Atomic(UInt64).new(0)

      # Unique across pools, to tell connections apart in logs
      @id : UInt64 = @@last_id.add(1) &+ 1
      @lock = Mutex.new
      @pending = 0
      @upstream : Upstream?
      @error : Upstream::Error?
      @ready = Channel(Nil).new # closed when connected or failed

      def to_s(io : IO) : Nil
        io << "upstream #" << @id
      end

      # Channel counts, for logs
      def stats : String
        @lock.synchronize do
          if upstream = @upstream
            "#{upstream.channels}/#{upstream.channel_max} channels, #{@pending} pending"
          elsif @error
            "failed"
          else
            "connecting, #{@pending} pending"
          end
        end
      end

      # Counts a pending channel, unless the upstream is full or unusable.
      # *channel_max* applies until the upstream has negotiated its own.
      def reserve?(channel_max : UInt16) : Bool
        @lock.synchronize do
          return false if full?(channel_max)
          @pending += 1
          true
        end
      end

      private def full?(channel_max : UInt16) : Bool
        return true if @error
        if upstream = @upstream
          upstream.closed? || upstream.channels + @pending >= upstream.channel_max
        else
          @pending >= channel_max
        end
      end

      # Opens a channel reserved with `#reserve?`
      def open_channel(downstream_channel : DownstreamChannel, deadline : Time::Instant) : Nil
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

    # How long `#open_channel` waits for a channel, including connecting to upstream
    OPEN_CHANNEL_TIMEOUT = 10.seconds

    # RabbitMQ's default, the guess until the pool's first connection has negotiated
    RABBITMQ_CHANNEL_MAX = 2047_u16

    @lock = Mutex.new
    @upstreams = Deque(PooledUpstream).new
    # From the latest connection, likely what the next one negotiates too
    @negotiated_channel_max : UInt16?

    def initialize(@host : String, @port : Int32, @tls_ctx : OpenSSL::SSL::Context::Client?, @credentials : Credentials, @idle_connection_timeout : Int32, @max_upstream_channels : UInt16,
                   @open_channel_timeout : Time::Span = OPEN_CHANNEL_TIMEOUT)
      @max_upstream_channels = UInt16::MAX if @max_upstream_channels.zero?
      spawn shrink_pool_loop, name: "shrink pool loop"
    end

    # Returns when the upstream has told *downstream_channel* that it's open
    def open_channel(downstream_channel : DownstreamChannel) : Nil
      deadline = Time.instant + @open_channel_timeout
      loop do
        pooled = @lock.synchronize do
          channel_max = @negotiated_channel_max || Math.min(@max_upstream_channels, RABBITMQ_CHANNEL_MAX)
          @upstreams.find(&.reserve?(channel_max)) || add_upstream(channel_max).tap(&.reserve?(channel_max))
        end
        Log.debug { "Opening channel on #{pooled} (#{pooled.stats})" }
        begin
          return pooled.open_channel(downstream_channel, deadline)
        rescue Upstream::ChannelMaxReached
          # the server negotiated a lower channel_max than we reserved for
          Log.debug { "No free channel on #{pooled} (#{pooled.stats}), trying another" }
        end
      end
    end

    # Must be called with the lock held
    private def add_upstream(channel_max : UInt16) : PooledUpstream
      pooled = PooledUpstream.new
      Log.debug { "Connecting #{pooled}, channel_max #{channel_max} until negotiated" }
      @upstreams.unshift pooled
      spawn connect(pooled), name: "ChannelPool#connect"
      pooled
    end

    private def connect(pooled : PooledUpstream) : Nil
      upstream = begin
        Upstream.new(@host, @port, @tls_ctx, @credentials, @max_upstream_channels, @open_channel_timeout)
      rescue ex
        Log.warn { "Could not connect #{pooled}: #{ex.message}" }
        pooled.failed(ex)
        return
      end
      Log.info { "Adding #{pooled}, channel_max #{upstream.channel_max}" }
      negotiated(upstream.channel_max)
      pooled.connected(upstream)
      upstream.read_loop
    ensure
      removed = @lock.synchronize { @upstreams.delete pooled }
      Log.debug { "Removed #{pooled} from pool" } if removed
    end

    private def negotiated(channel_max : UInt16) : Nil
      @lock.synchronize do
        previous = @negotiated_channel_max
        if previous && previous != channel_max
          Log.info { "Upstream channel_max changed from #{previous} to #{channel_max}" }
        end
        @negotiated_channel_max = channel_max
      end
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
              Log.debug { "Closing idle #{u}" }
              begin
                u.close "Pooled connection closed due to inactivity"
              rescue ex
                Log.error { "Problem closing upstream: #{ex.inspect}" }
              end
            elsif u.closed?
              Log.error { "Removing closed #{u} from pool" }
            else
              @upstreams.unshift u
            end
          end
        end
      end
    end
  end
end
