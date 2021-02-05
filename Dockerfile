FROM crystallang/crystal:0.36.1-alpine as builder
WORKDIR /tmp
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN shards build --release --production --static
RUN strip bin/*

FROM scratch
USER 2:2
COPY --from=builder /etc/ssl/cert.pem /etc/ssl/
COPY --from=builder /tmp/bin/amqproxy /amqproxy
EXPOSE 5673
ENTRYPOINT ["/amqproxy", "--listen=0.0.0.0"]
