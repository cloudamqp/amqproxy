module AMQProxy
  class Pool
    getter :size

    def initialize(@host : String, @port : Int32, @tls : Bool, @log : Logger)
      @pools = Hash(Tuple(String, String, String), Deque(Upstream)).new do |h, k|
        h[k] = Deque(Upstream).new
      end
      @size = 0
      spawn shrink_loop
    end

    def borrow(user : String, password : String, vhost : String, &block : (Upstream | Nil) -> _)
      q = @pools[{ user, password, vhost }]
      u = q.shift do
        @size += 1
        Upstream.new(@host, @port, @tls, @log).connect(user, password, vhost)
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
        q.not_nil!.push u
      end
    end

    def close
      shrink "AMQProxy shutdown"
    end

    private def shrink_loop
      loop do
        sleep 60
        shrink "Pooled connection closed due to inactivity"
      end
    end

    private def shrink(reason)
      @pools.each_value do |q|
        while u = q.shift?
          @size -= 1
          begin
            u.close reason
          rescue ex
            @log.error "Problem closing upstream: #{ex.inspect}"
          end
        end
      end
    end
  end
end
