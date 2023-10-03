FROM php:7.4-cli
WORKDIR /app

RUN apt-get update -q \
  && apt-get install -qq cmake libssl-dev git unzip \
  && rm -rf /var/lib/apt/lists/*

# Install librabbitmq (https://github.com/alanxz/rabbitmq-c)
RUN \
  curl --location --silent --output /tmp/rabbitmq-c.tar.gz https://github.com/alanxz/rabbitmq-c/archive/v0.10.0.tar.gz \
  && mkdir -p /tmp/rabbitmq-c/build \
  && tar --gunzip --extract --strip-components 1 --directory /tmp/rabbitmq-c --file /tmp/rabbitmq-c.tar.gz \
  && cd /tmp/rabbitmq-c/build \
  && cmake -DBUILD_EXAMPLES=OFF -DBUILD_TESTS=OFF -DBUILD_TOOLS=OFF -DENABLE_SSL_SUPPORT=ON .. \
  && cmake --build . --target install \
  && ln -s /usr/local/lib/x86_64-linux-gnu/librabbitmq.so.4 /usr/local/lib/

# Install php-amqp (https://github.com/php-amqp/php-amqp)
RUN echo /usr/local | pecl install amqp

COPY *.php ./
