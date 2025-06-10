FROM 84codes/crystal:1.16.3-alpine AS builder
WORKDIR /usr/src/amqproxy
COPY Makefile shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
ARG CRYSTAL_FLAGS="--static --release"
RUN make bin/amqproxy && mkdir amqproxy && mv bin/amqproxy amqproxy/
COPY README.md LICENSE extras/amqproxy.service amqproxy/
COPY config/example.ini amqproxy/amqproxy.ini
ARG TARGETARCH
RUN tar zcvf amqproxy-$(shards version)_static-$TARGETARCH.tar.gz amqproxy/

FROM scratch
COPY --from=builder /usr/src/amqproxy/*.tar.gz .
