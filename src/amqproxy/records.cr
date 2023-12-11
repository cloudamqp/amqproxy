require "./upstream"
require "./client"

module AMQProxy
  record UpstreamChannel, upstream : Upstream, channel : UInt16 do
    def write(frame)
      frame.channel = @channel
      @upstream.write frame
    end

    def unassign
      @upstream.unassign_channel(@channel)
    end
  end

  record DownstreamChannel, client : Client, channel : UInt16 do
    def write(frame)
      frame.channel = @channel
      @client.write(frame)
    end

    def close
      @client.close_channel(@channel)
    end
  end

  record Credentials, user : String, password : String, vhost : String
end

# Be able to overwrite channel id
module AMQ
  module Protocol
    abstract struct Frame
      setter channel
    end
  end
end
