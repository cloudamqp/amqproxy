#!/bin/bash

set -x
set -e

docker compose \
  --file spec/docker-compose.yml \
  up \
  --remove-orphans \
  --force-recreate \
  --renew-anon-volumes \
  --build \
  --exit-code-from spec
