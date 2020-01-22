require "amqp-client"

abort "Usage: #{PROGRAM_NAME} <amqp-url> <msg-count>" if ARGV.size != 2
url, msgs = ARGV
puts "Publishing #{msgs} msgs on one connection"
AMQP::Client.start(url) do |c|
  c.channel do |ch|
    q = ch.queue("test")
    msgs.to_i.times do |idx|
      q.publish "msg #{idx}"
    end
  end
end
