FROM 84codes/crystal:1.13.2-ubuntu-22.04

RUN apt-get update && apt-get install -y rabbitmq-server

WORKDIR /tmp

# We want to install shards before copying code/spec files for quicker runs
COPY shard.yml shard.lock ./
RUN shards install

COPY src/ src/
COPY spec/ spec/

COPY spec/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
