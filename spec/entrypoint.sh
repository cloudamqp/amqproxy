#!/bin/bash
set -eux

export RABBITMQ_PID_FILE=/tmp/rabbitmq.pid

# Start RabbitMQ
rabbitmq-server -detached

# Wait for RabbitMQ to start
rabbitmqctl wait $RABBITMQ_PID_FILE

crystal --version
crystal spec --order random --verbose
