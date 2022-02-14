FROM 84codes/crystal:latest-alpine AS builder

WORKDIR /tmp
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN shards build --release --production --static

FROM alpine:latest
USER 2:2
COPY --from=builder /tmp/bin/amqproxy /amqproxy
EXPOSE 5673
ENTRYPOINT ["/amqproxy", "--listen=0.0.0.0"]
