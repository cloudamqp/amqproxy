# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
