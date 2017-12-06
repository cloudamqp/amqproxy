# AMQProxy

An intelligent AMQP proxy, with AMQP connection pooling/reusing etc. Allows PHP clients to keep long lived connections to upstream servers.

## Installation

[Install Crystal](https://crystal-lang.org/docs/installation/)

```
shards build --release
cp bin/amqproxy /usr/local/bin
cp extras/amqproxy.service /etc/systemd/systems/
service start amqproxy
```

You probably want to modify `/etc/systemd/systems/amqproxy.service` and configure another upstream host.


## Usage

`bin/amqproxy -p PORT -u AMQP_URL`

Then from your AMQP client connect to localhost:5673, it will resuse connections made to the upstream.
