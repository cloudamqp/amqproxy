require "amqp-client"

abort "Usage: #{PROGRAM_NAME} <amqp-url> <msg-count>" if ARGV.size != 2
url, msgs = ARGV
puts "Publishing #{msgs} msgs"
msgs.to_i.times do |idx|
  AMQP::Client.start(url) do |c|
    c.channel do |ch|
      q = ch.queue("test")
      q.publish "msg #{idx}"
    end
  end
end
