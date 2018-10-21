FROM crystallang/crystal
WORKDIR /app
COPY . .
RUN echo start \
    && mkdir bin \
    && crystal build --error-trace --release -o bin/amqproxy src/amqproxy.cr \
    && echo ok

ENV HOST=127.0.0.1
ENV PORT=5673
ENV REMOTE=amqps://127.0.0.1:5672
ENV HEALTHCHECK_PORT=8080
CMD bin/amqproxy \
        -l $HOST \
        -p $PORT \
        --healcheck-port $HEALTHCHECK_PORT \
        $REMOTE

