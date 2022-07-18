# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
