#!/bin/sh

set -x

/toxiproxy-cli toxic \
  add \
  --type reset_peer \
  --attribute timeout=2000 \
  --toxicName reset_peer between-proxy-and-broker

echo "Toxic added, sleeping..."

# We sleep so the container keeps running as otherwise all containers would stop
# as we are using --exit-code-from (implies --abort-on-container-exit)
sleep 900
