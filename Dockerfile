FROM 84codes/crystal:1.13.2-alpine AS builder
WORKDIR /tmp
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN shards build --production --release --static

FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem
COPY --from=builder /tmp/bin/amqproxy /
USER 1000:1000
EXPOSE 5673 15673
ENV GC_UNMAP_THRESHOLD=1
ENTRYPOINT ["/amqproxy", "--listen=0.0.0.0"]
