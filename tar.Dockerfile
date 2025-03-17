FROM 84codes/crystal:1.15.1-alpine AS builder
WORKDIR /usr/src/amqproxy
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN shards build --production --release --static --debug
COPY README.md LICENSE extras/amqproxy.service amqproxy/
COPY config/example.ini amqproxy/amqproxy.ini
RUN mv bin/* amqproxy/
ARG TARGETARCH
RUN tar zcvf amqproxy-$(shards version)_static-$TARGETARCH.tar.gz amqproxy/

FROM scratch
COPY --from=builder /usr/src/amqproxy/*.tar.gz .
