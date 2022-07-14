require "amqp-client"

abort "Usage: #{PROGRAM_NAME} <amqp-url> <client-count> <msg-count-per-client>" if ARGV.size != 3
url, conns, msgs = ARGV
puts "Publishing #{msgs} msgs on #{conns} connections"
done = Channel(Nil).new
conns.to_i.times do |_idx|
  spawn do
    AMQP::Client.start(url) do |c|
      c.channel do |ch|
        q = ch.queue("test")
        msgs.to_i.times do |msg_idx|
          q.publish "msg #{msg_idx}"
        end
      end
    end
  ensure
    done.send nil
  end
end

conns.to_i.times do
  done.receive?
end
