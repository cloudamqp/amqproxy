FROM crystallang/crystal:0.35.1-alpine as build
WORKDIR /tmp
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN shards build --release --production --static
RUN strip bin/*

FROM alpine:latest
COPY --from=build /tmp/bin/ /usr/bin/

USER nobody:nogroup
EXPOSE 5673
ENTRYPOINT ["/usr/bin/amqproxy"]
