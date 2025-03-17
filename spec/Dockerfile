FROM 84codes/crystal:1.15.1-ubuntu-22.04

RUN apt-get update && apt-get install -y rabbitmq-server

WORKDIR /tmp

# We want to install shards before copying code/spec files for quicker runs
COPY shard.yml shard.lock ./
RUN shards install

COPY src/ src/
COPY spec/ spec/

COPY spec/config.ini /tmp/config.ini
COPY spec/config_empty.ini /tmp/config_empty.ini

COPY spec/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
