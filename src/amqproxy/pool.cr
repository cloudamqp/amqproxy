module AMQProxy
  class Pool
    def initialize(@host : String, @port : Int32, @tls : Bool)
      @pools = {} of String => Deque(Upstream)
    end

    def borrow(user : String, password : String, vhost : String, &block : (Upstream | Nil) -> _)
      q = @pools[[user, password, vhost].join] ||= Deque(Upstream).new
      u = q.shift do
        Upstream.new(@host, @port, @tls).connect(user, password, vhost)
      end
      block.call u
    ensure
      if u.nil?
        print "Upstream connection could not be established\n"
      elsif u.closed?
        print "Upstream connection closed when returned\n"
      elsif !q.nil?
        q.push u
      end
    end
  end
end
