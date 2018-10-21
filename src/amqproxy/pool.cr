module AMQProxy
  class Pool
    getter :size
    def initialize(@host : String, @port : Int32, @tls : Bool, @log : Logger)
      @pools = {} of String => Deque(Upstream)
      @size = 0
    end

    def upstream
      "#{@host}:#{@port}"
    end

    def borrow(user : String, password : String, vhost : String, &block : (Upstream | Nil) -> _)
      q = @pools[[user, password, vhost].join] ||= Deque(Upstream).new
      u = q.shift do
        @size += 1
        Upstream.new(@host, @port, @tls, @log).connect(user, password, vhost)
      end
      block.call u
    ensure
      if u.nil?
        @size -= 1
        @log.error "Upstream connection could not be established"
      elsif u.closed?
        @size -= 1
        @log.error "Upstream connection closed when returned"
      elsif !q.nil?
        q.push u
      end
    end
  end
end
