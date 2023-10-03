#!/bin/bash

set -x
set -e

# --force-recreate and --renew-anon-volumes needed to start fresh every time
# otherwise broker datadir volume may be re-used

docker-compose \
  --file test/integration-php/docker-compose.yml \
  up \
  --remove-orphans \
  --force-recreate \
  --renew-anon-volumes \
  --build \
  --exit-code-from php-amqp
