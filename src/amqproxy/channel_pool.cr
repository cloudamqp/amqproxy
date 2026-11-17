require "openssl"
require "log"
require "./records"
require "./upstream"

module AMQProxy
  class ChannelPool
    Log = ::Log.for(self)
    @lock = Mutex.new
    @upstreams = Deque(Upstream).new
    # The connection attempt in progress, if any, guarded by @lock
    @dial : Dial? = nil

    # A connection attempt that clients needing a new upstream wait for,
    # instead of each opening a connection of its own
    private class Dial
      getter error : Exception? = nil
      @done = Channel(Nil).new

      def finish(@error : Exception?) : Nil
        @done.close
      end

      def wait : Nil
        @done.receive?
      end
    end

    def initialize(@host : String, @port : Int32, @tls_ctx : OpenSSL::SSL::Context::Client?, @credentials : Credentials,
                   @idle_connection_timeout : Int32, @max_upstream_channels : UInt16,
                   @connect_timeout : Time::Span? = Upstream::CONNECT_TIMEOUT)
      spawn shrink_pool_loop, name: "shrink pool loop"
    end

    # Only picking an upstream happens under @lock. Connecting, and writing
    # Channel#Open, happen outside of it, so a slow or unresponsive upstream
    # only holds up the clients that use it, not every client in the pool.
    def get(downstream_channel : DownstreamChannel) : UpstreamChannel
      loop do
        reserved, dial, owner = @lock.synchronize do
          if upstream_channel = reserve_on_connected_upstream(downstream_channel)
            {upstream_channel, nil, false}
          elsif dial = @dial
            {nil, dial, false}
          else
            {nil, @dial = Dial.new, true}
          end
        end
        if reserved
          return reserved if send_channel_open(reserved)
        elsif dial
          if owner
            add_upstream(dial)
          else
            dial.wait
            if ex = dial.error
              raise ex.is_a?(Upstream::AccessError) ? Upstream::AccessError.new(ex.message, cause: ex) : Upstream::Error.new(ex.message, cause: ex)
            end
          end
        end
        # retry: a new upstream is at the front of the pool, or a failed one is closed
      end
    end

    # Must be called with @lock held. No I/O, so the upstream is back in the
    # pool before anything can yield, and its read_loop can remove it if it
    # closes.
    private def reserve_on_connected_upstream(downstream_channel) : UpstreamChannel?
      @upstreams.size.times do
        upstream = @upstreams.shift? || break
        next if upstream.closed?
        begin
          upstream_channel = upstream.reserve_channel(downstream_channel)
          @upstreams.unshift(upstream)
          return upstream_channel
        rescue Upstream::ChannelMaxReached
          @upstreams.push(upstream)
        end
      end
      nil
    end

    # False if the upstream connection failed, it's then closed, so the next
    # attempt picks another upstream or connects a new one
    private def send_channel_open(upstream_channel : UpstreamChannel) : Bool
      upstream_channel.upstream.send_channel_open(upstream_channel.channel)
      true
    rescue ex : Upstream::WriteError
      Log.warn { "Upstream connection failed while opening a channel, retrying: #{ex.message}" }
      upstream_channel.upstream.release_channel(upstream_channel.channel)
      false
    end

    private def add_upstream(dial : Dial) : Nil
      upstream = begin
        Upstream.new(@host, @port, @tls_ctx, @credentials, @max_upstream_channels, @connect_timeout)
      rescue ex
        @lock.synchronize { @dial = nil }
        dial.finish(ex)
        raise ex.is_a?(Upstream::Error) ? ex : Upstream::Error.new(ex.message, cause: ex)
      end
      Log.info { "Adding upstream connection" }
      @lock.synchronize do
        @upstreams.unshift upstream
        @dial = nil
      end
      dial.finish(nil)
      spawn(name: "Upstream#read_loop") do
        upstream.read_loop
      ensure
        @upstreams.delete upstream
      end
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
