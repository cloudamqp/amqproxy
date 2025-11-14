FROM 84codes/crystal:1.17.0-debian-12 AS builder
WORKDIR /usr/src/amqproxy
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN shards build --production --release

FROM debian:12-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/src/amqproxy/bin/amqproxy /usr/bin/amqproxy
USER 1000:1000
EXPOSE 5673 15673
ENV GC_UNMAP_THRESHOLD=1
ENTRYPOINT ["/usr/bin/amqproxy", "--listen=0.0.0.0"]
