module AMQProxy
  class Pool
    getter :size

    def initialize(@host : String, @port : Int32, @tls : Bool, @log : Logger)
      @pools = Hash(Tuple(String, String, String), Deque(Upstream)).new do |h, k|
        h[k] = Deque(Upstream).new
      end
      @lock = Mutex.new
      @size = 0
      spawn shrink_pool_loop, name: "shrink pool loop"
    end

    def borrow(user : String, password : String, vhost : String, &block : Upstream -> _)
      @lock.synchronize do
        q = @pools[{ user, password, vhost }]
        u = q.shift do
          @size += 1
          Upstream.new(@host, @port, @tls, @log).connect(user, password, vhost)
        end
      end
      yield u
    ensure
      if u.nil?
        @size -= 1
        @log.error "Upstream connection could not be established"
      elsif u.closed?
        @size -= 1
        @log.error "Upstream connection closed when returned"
      else
        u.last_used = Time.monotonic
        @lock.synchronize do
          @pools[{ user, password, vhost }].push u
        end
      end
    end

    def close
      @lock.synchronize do
        @pools.each_value do |q|
          while u = q.shift?
            begin
              u.close "AMQProxy shutdown"
            rescue ex
              @log.error "Problem closing upstream: #{ex.inspect}"
            end
          end
        end
        @size = 0
      end
    end

    private def shrink_pool_loop
      loop do
        sleep 5.seconds
        @lock.synchronize do
          @pools.each_value do |q|
            q.size.times do
              u = q.shift
              if u.last_used > Time.monotonic - 5.seconds
                q.push u
                next
              end
              @size -= 1
              begin
                u.close "Pooled connection closed due to inactivity"
              rescue ex
                @log.error "Problem closing upstream: #{ex.inspect}"
              end
            end
          end
        end
      end
    end
  end
end
