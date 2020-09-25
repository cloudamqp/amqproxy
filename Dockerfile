FROM crystallang/crystal:latest-alpine as build
WORKDIR /app
COPY . .
RUN shards build --release --production --static
RUN strip bin/*

FROM alpine:latest

WORKDIR /app
COPY --from=build /app/bin /app/bin

ENV LISTEN_ADDRESS=0.0.0.0
ENV LISTEN_PORT=5673
ENV AMQP_URL=amqp://127.0.0.1:5672
CMD bin/amqproxy -l $LISTEN_ADDRESS -p $LISTEN_PORT $AMQP_URL -d
