FROM alpine:latest AS builder
RUN apk add crystal shards musl-dev openssl-dev openssl-libs-static zlib-dev zlib-static

WORKDIR /tmp
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN shards build --release --production --static
#RUN strip bin/*

FROM alpine:latest
USER 2:2
COPY --from=builder /tmp/bin/amqproxy /amqproxy
EXPOSE 5673
ENTRYPOINT ["/amqproxy", "--listen=0.0.0.0"]
