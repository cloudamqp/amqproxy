FROM crystallang/crystal:0.35.1-alpine as build
WORKDIR /tmp
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN shards build --release --production --static
RUN strip bin/*

FROM scratch
COPY --from=build /tmp/bin/amqproxy /amqproxy
EXPOSE 5673
ENTRYPOINT ["/amqproxy"]
