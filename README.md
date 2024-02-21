# AMQProxy

An intelligent AMQP proxy with AMQP connection and channel pooling/reusing. Allows e.g. PHP clients to keep long lived connections to upstream servers, increasing publishing speed with a magnitude or more.

In the AMQP protocol, if you open a connection the client and the server has to exchange 7 TCP packages. If you then want to publish a message you have to open a channel which requires 2 more, and then to do the publish you need at least one more, and then to gracefully close the connection you need 4 more packages. In total 15 TCP packages, or 18 if you use AMQPS (TLS). For clients that can't for whatever reason keep long-lived connections to the server this has a considerable latency impact.

This proxy server, if run on the same machine as the client can save all that latency. When a connection is made to the proxy the proxy opens a connection to the upstream server, using the credentials the client provided. AMQP traffic is then forwarded between the client and the server but when the client disconnects the proxy intercepts the Channel Close command and instead keeps it open on the upstream server (if deemed safe). Next time a client connects (with the same credentials) the connection to the upstream server is reused so no TCP packages for opening and negotiating the AMQP connection or opening and waiting for the channel to be opened has to be made.

Only "safe" channels are reused, that is channels where only Basic Publish or Basic Get (with no_ack) has occurred. Any channels who has subscribed to a queue will be closed when the client disconnects. However, the connection to the upstream AMQP server are always kept open and can be reused.

In our benchmarks publishing one message per connection to a server (using TLS) with a round-trip latency of 50ms, takes on avarage 10ms using the proxy and 500ms without. You can read more about the proxy here [Maintaining long-lived connections with AMQProxy](https://www.cloudamqp.com/blog/2019-05-29-maintaining-long-lived-connections-with-AMQProxy.html)

As of version 2.0.0 connections to the server can be shared by multiple client connections. When a client opens a channel it will get a channel on a shared upstream connection, the proxy will remap the channel numbers between the two. Many client connections can therefor share a single upstream connection. The benefit is that way fewer connections are needed to the upstream server. For instance, establihsing 10.000 connections after a server reboot might normally take several minutes, but with this proxy it can happen in seconds.

## Installation

### Debian/Ubuntu

Packages are available at [Packagecloud](https://packagecloud.io/cloudamqp/amqproxy). Install the latest version with:

```sh
curl -fsSL https://packagecloud.io/cloudamqp/amqproxy/gpgkey | gpg --dearmor | sudo tee /usr/share/keyrings/amqproxy.gpg > /dev/null
. /etc/os-release
echo "deb [signed-by=/usr/share/keyrings/amqproxy.gpg] https://packagecloud.io/cloudamqp/amqproxy/$ID $VERSION_CODENAME main" | sudo tee /etc/apt/sources.list.d/amqproxy.list
sudo apt-get update
sudo apt-get install amqproxy
```

If you need to install a specific version, do so using the following command:
`sudo apt install lavinmq=<version>`. This works for both upgrades and downgrades.

### Docker/Podman

Docker images are published at [Docker Hub](https://hub.docker.com/r/cloudamqp/amqproxy). Fetch and run the latest version with:

```sh
docker run --rm -it -p 5673:5673 cloudamqp/amqproxy amqp://SERVER:5672
```

Note: If you are running the upstream server on localhost then you will have to add the `--network host` flag to the docker run command.

Then from your AMQP client connect to localhost:5673, it will resuse connections made to the upstream. The AMQP_URL should only include protocol, hostname and port (only if non default, 5672 for AMQP and 5671 for AMQPS). Any username, password or vhost will be ignored, and it's up to the client to provide them.

## Installation (from source)

[Install Crystal](https://crystal-lang.org/install/)

```
shards build --release --production
cp bin/amqproxy /usr/bin
cp extras/amqproxy.service /etc/systemd/system/
systemctl enable amqproxy
systemctl start amqproxy
```

You probably want to modify `/etc/systemd/system/amqproxy.service` and configure another upstream host.


## Configuration

### Available settings

| Setting                 | Description                                                                                                                                                                                                                                                                                                                                                                     | Command line                                | Environment variable      | Config file setting                              | Default value |
|-------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------|---------------------------|--------------------------------------------------|---------------|
| Listen address          | Address to listen on. This is the hostname/IP address which will be the target of clients                                                                                                                                                                                                                                                                                       | `--listen` / `-l`                           | `LISTEN_ADDRESS`          | `[listen] > address` or `[listen] > bind` | `localhost`   |
| Listen port             | Port to listen on. This is the port which will be the target of clients                                                                                                                                                                                                                                                                                                         | `--port` / `-p`                             | `LISTEN_PORT`             | `[listen] > port`                             | `5673`        |
| Log level               | Controls log verbosity.<br><br>Available levels (see [84codes/logger.cr](https://github.com/84codes/logger.cr/blob/main/src/logger.cr#L86)):<br> - `DEBUG`: Low-level information for developers<br> - `INFO`: Generic (useful) information about system operation<br> - `WARN`: Warnings<br> - `ERROR`: Handleable error conditions<br> - `FATAL`: Unhandleable errors that results in a program crash | `--debug` / `-d`: Sets the level to `DEBUG` | -                         | `[main] > log_level`                         | `INFO`          |
| Idle connection timeout | Maximum time in seconds an unused pooled connection stays open                                                                                                                                                                                                                                                                                                                  | `--idle-connection-timeout` / `-t`          | `IDLE_CONNECTION_TIMEOUT` | `[main] > idle_connection_timeout`           | `5`           |
| Upstream                | AMQP URL that points to the upstream RabbitMQ server to which the proxy should connect to. May only contain scheme, host & port (optional). Example: `amqps://rabbitmq.example.com`                                                                                                                                                                                             | Pass as argument after all options          | `AMQP_URL`                | `[main] > upstream`                          |               |

### How to configure

There are three ways to configure the AMQProxy.
* Environment variables
* Passing options & argument via the command line
  * Usage: `amqproxy [options] [amqp upstream url]`
  * Additional options, that are not mentioned in the table above:
    * `--config` / `-c`: Load config file at given path
    * `--help` / `-h`: Shows help
    * `--version` / `-v`: Displays AMQProxy version
* Config file
  * You can find an example at [config/example.ini](config/example.ini)

#### Precedence
1. Config file
2. Command line options & argument
3. Environment variables

Settings that are avilable in the config file will override the corresponding command line options. A command line option will override the corresponding environment variable. And so on.
The different configuration approaches can also be mixed.
