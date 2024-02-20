ARG image=84codes/crystal:latest-debian-11
FROM $image AS builder
RUN apt-get update && \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y dpkg help2man lintian
WORKDIR /tmp/amqproxy
COPY README.md shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN shards build --production --release

COPY extras/amqproxy.service extras/amqproxy.service
COPY config/example.ini config/example.ini
COPY build/deb build/deb
RUN build/deb $(shards version) 1

FROM scratch
COPY --from=builder /tmp/amqproxy/builds .
