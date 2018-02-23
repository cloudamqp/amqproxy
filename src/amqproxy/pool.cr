module AMQProxy
  class Pool
    def initialize(@max_size : Int32, @host : String, @port : Int32, @tls : Bool)
      @pools = {} of String => Deque(Upstream)
    end

    def borrow(user : String, password : String, vhost : String, &block : Upstream -> _)
      q = @pools[[user, password, vhost].join] ||= Deque(Upstream).new
      s = q.shift { Upstream.new(@host, @port, @tls, user, password, vhost) }
      block.call s
    ensure
      if s.nil?
        puts "Socket is nil"
      elsif s.closed?
        puts "Socket closed when returned"
      else
        q.try { |q| q.push s }
      end
    end
  end
end
