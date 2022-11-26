FROM 84codes/crystal:latest-alpine AS builder
WORKDIR /tmp
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN shards build --production --release --debug

FROM alpine:latest
RUN apk add --no-cache libssl1.1 pcre libevent libgcc
COPY --from=builder /tmp/bin/amqproxy /usr/bin/amqproxy
USER nobody:nogroup
EXPOSE 5673
ENTRYPOINT ["/usr/bin/amqproxy", "--listen=0.0.0.0"]
