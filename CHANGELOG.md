# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [v2.0.2] - 2024-08-25

- Compile with Crystal 1.13.2, fixes a memory leak in Hash.

## [v2.0.1] - 2024-07-11

- Return unused memory faster to the OS using GC_UNMAP_THRESHOLD=1 in Dockerfile and systemd service file
- Compile with Crystal 1.13.0, fixes a potential memory leak in Log

## [v2.0.0] - 2024-06-17

- Main difference against v1.x is that channels are pooled, multiple client channels are shared on a single upstream connection, dramatically decreasing the number of upstream connections needed
- IPv6 addresses in brackets supported in upstream URL (eg. amqp://[::1])
- Otherwise unchanged from v2.0.0-rc.8

## [v2.0.0-rc.8] - 2024-05-12

- Allow large client frame sizes, but split body frames to client if smaller than upstream frame size, to support large Header frames

## [v2.0.0-rc.7] - 2024-05-12

- Send all GetOk response frames in one TCP packet

## [v2.0.0-rc.6] - 2024-05-11

- Bugfix: Send Connection.Close-ok to client before closing TCP socket
- Bugfix: Pass Channel.Close-ok down to client

## [v2.0.0-rc.5] - 2024-05-11

- Bugfix: negotiate frame_max 4096 for downstream clients

## [v2.0.0-rc.4] - 2024-05-11

- Bufix: Only send channel.close once, and gracefully wait for closeok
- Buffer publish frames and only send full publishes as RabbitMQ doesn't support channel.close in the middle of a publish frame sequence
- Optimization: only flush socket buffer after a full publish sequence, not for each frame

## [v2.0.0-rc.3] - 2024-05-09

- Never reuse channels, even publish only channels are not safe if not all publish frames for a message was sent before the client disconnected
- Don't log normal client disconnect errors
- Don't allow busy connection to dominate, Fiber.yield every 4k msgs
- --term-timout support, wait X seconds after signal TERM and then forefully close remaining connections
- Always negotate 4096 frame_max size, as that's the minimum all clients support

## [v2.0.0-rc.2] - 2024-03-09

- Heartbeat support on the client side
- Connection::Blocked frames are passed to clients
- On channel errors correctly pass closeok to upstream server

## [v2.0.0-rc.1] - 2024-02-19

- Rewrite of the proxy where Channels are pooled rather than connections. When a client opens a channel it will get a channel on a shared upstream connection, the proxy will remap the channel numbers between the two. Many client connections can therefor share a single upstream connection. Upside is that way fewer connections are needed to the upstream server, downside is that if there's a misbehaving client, for which the server closes the connection, all channels for other clients on that shared connection will also be closed.

## [v1.0.0] - 2024-02-19

- Nothing changed from v0.8.14

## [v0.8.14] - 2023-10-20

- Update current client in `Upstream#read_loop` [#138](https://github.com/cloudamqp/amqproxy/pull/138)

## [v0.8.13] - 2023-10-11

- Disconnect clients on broken upstream connection [#128](https://github.com/cloudamqp/amqproxy/pull/128)

## [v0.8.12] - 2023-09-20

No changes from 0.8.11. Tagged to build missing Debian/Ubuntu packages.

## [v0.8.11] - 2023-06-06

No changes from 0.8.10.

## [v0.8.10] - 2023-05-16

No changes from 0.8.9.

## [0.8.9] - 2023-05-16

- Alpine Docker image now uses user/group `amqpproxy` (1000:1000) [#107](https://github.com/cloudamqp/amqproxy/pull/107)

- Require updated amq-protocol version that fixes tune negotiation issue

## [0.8.8] - 2023-05-10

- Same as 0.8.7 but fixes missing PCRE2 dependency in the `cloudamqp/amqproxy` Docker Hub image

## [0.8.7] - 2023-05-08

- Disables the Nagle algorithm on the upstream socket as well ([#113](https://github.com/cloudamqp/amqproxy/pull/113))
- Added error handling for IO error ([#104](https://github.com/cloudamqp/amqproxy/pull/104))

## [0.8.6] - 2023-03-01

- Reenable TCP nodelay on the server connection, impacted performance

## 0.8.3, 0.8.4, 0.8.5

* 0.8.3 was tagged 2023-02-15 but a proper release was never created (release workflow failed)
* 0.8.4 was tagged (and released) 2023-03-01 but it was built without bumping the version, so it reports 0.8.3
* 0.8.5 was tagged 2023-03-01 but a proper release was never created (release workflow did not run)

## [0.8.2] - 2022-11-26

- Build RPM packages for Fedora 37
- Build DEB packages for Ubuntu 22.04
- Locks around socket writes
- Default systemd service file uses /etc/amqproxy.ini
- Set a connection name on upstream connections

## [0.8.1] - 2022-11-16

- New amq-protocol.cr without a StringPool, which in many cases caused a memory leak

## [0.8.0] - 2022-11-15

- Prevent race conditions by using more locks
- Don't disable nagles algorithm (TCP no delay), connections are faster with the algorithm enabled
- idle_connection_timeout can be specificed as an environment variable
- Container image uses libssl1.1 (from libssl3 which isn't fully supported)

## [0.7.0] - 2022-08-02

- Inform clients of product and version via Start frame
- Check upstream connection before lending it out
- Graceful shutdown, waiting for connections to close
- Don't try to reuse channels closed by server for new connections
- Notify upstream that consumer cancellation is supported
- Reuse a single TLS context for all upstream TLS connections, saves memory
- Fixed broken OpenSSL in the Docker image

## [0.6.1] - 2022-07-14

- Build package for Debian 11 (bullseye) ([#73](https://github.com/cloudamqp/amqproxy/issues/73))
- [Bump dependencies](https://github.com/cloudamqp/amqproxy/commit/3cb5a4b6fdaf9ee2c58dc6cb9bdb8a09a7315669)
- Fix bug with connection pool shrinking ([#70](https://github.com/cloudamqp/amqproxy/pull/70))
- Support for config files ([#64](https://github.com/cloudamqp/amqproxy/issues/64))

## [0.6.0] - 2022-07-14

This version never got built.

## [0.5.11] - 2022-03-06

- Same as 0.5.10, only to test release automation

## [0.5.10] - 2022-03-06

- Include error cause in upstream error log ([#67](https://github.com/cloudamqp/amqproxy/issues/67))

## [0.5.9] - 2022-02-14

### Fixed

- TLS cert verification works for container images again

## [0.5.8] - 2022-02-01

### Fixed

- Don't parse timestamp value, it can be anyting

## [0.5.7] - 2021-09-27

### Added

- Docker image for arm64

## [0.5.6] - 2021-06-20

### Fixed

- dockerfile syntax error

## [0.5.5] - 2021-06-20

### Added

- --idle-connection-timeout option, for how long an idle connection the pool will stay open

## [0.5.4] - 2021-04-07

### Changed

- Wait at least 5s before closing an upstream connection

### Fixed

- Close client socket on write error
- Close Upstreadm socket if client disconnects while deliverying body as state is then unknown

## [0.5.3] - 2021-03-30

### Fixed

- Skip body io if no client to deliver to

### Changed

- Better client disconnect handling
- Name all fibers for better debugging
- Not stripping binaries in Dockerfile
- Crystal 1.0.0

## [0.5.2] - 2021-03-10

### Added

- Heartbeat support for upstreams, uses the server suggest heartbeat interval

### Fixed

- Improved connection closed handling
