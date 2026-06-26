#!/bin/bash
# INIT-16875 sink-side functional test for self-managed Connect:
#   - 3 Kafka topics (topic-a, topic-b, topic-c) produce 5 messages each.
#   - 3 RabbitMQ queues (qa, qb, qc-fallback). qc-fallback is bound to
#     amq.direct with routing key `fallback-rk` so unmapped topics land there.
#   - Partial `rabbitmq.topic.queue.map`: topic-a->qa, topic-b->qb.
#     topic-c falls back to amq.direct + fallback-rk -> qc-fallback.
#   - Verifies messages land in the correct queues + nothing crosses over.

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

sleep 5

log "Provisioning RabbitMQ queues + fallback binding on amq.direct/fallback-rk"
docker exec rabbitmq rabbitmqadmin -u myuser -p mypassword declare queue name=qa durable=true
docker exec rabbitmq rabbitmqadmin -u myuser -p mypassword declare queue name=qb durable=true
docker exec rabbitmq rabbitmqadmin -u myuser -p mypassword declare queue name=qc-fallback durable=true
docker exec rabbitmq rabbitmqadmin -u myuser -p mypassword declare binding source=amq.direct destination=qc-fallback routing_key=fallback-rk

log "Producing 5 messages to each Kafka topic (topic-a, topic-b, topic-c)"
for t in topic-a topic-b topic-c; do
  playground topic produce --topic ${t} --nb-messages 5 --key "{}" --value "{}" --forced-value "value-${t}-{{ Sequence \"1\" }}"
done

log "Creating INIT-16875 RabbitMQ Sink connector (partial topic->queue map + fallback exchange)"
playground connector create-or-update --connector rabbitmq-sink-init16875 << EOF
{
  "connector.class": "io.confluent.connect.rabbitmq.sink.RabbitMQSinkConnector",
  "tasks.max": "1",
  "topics": "topic-a,topic-b,topic-c",
  "rabbitmq.topic.queue.map": "{\"topic-a\":\"qa\",\"topic-b\":\"qb\"}",
  "rabbitmq.exchange": "amq.direct",
  "rabbitmq.routing.key": "fallback-rk",
  "rabbitmq.delivery.mode": "PERSISTENT",
  "rabbitmq.host": "rabbitmq",
  "rabbitmq.username": "myuser",
  "rabbitmq.password": "mypassword",
  "key.converter": "org.apache.kafka.connect.storage.StringConverter",
  "value.converter": "org.apache.kafka.connect.converters.ByteArrayConverter",
  "confluent.topic.bootstrap.servers": "broker:9092",
  "confluent.topic.replication.factor": "1"
}
EOF

sleep 15

log "Asserting queue depths: qa=5 (topic-a), qb=5 (topic-b), qc-fallback=5 (topic-c via fallback)"
for q_expected in "qa 5" "qb 5" "qc-fallback 5"; do
  q=$(echo "$q_expected" | awk '{print $1}')
  expected=$(echo "$q_expected" | awk '{print $2}')
  actual=$(docker exec rabbitmq rabbitmqctl -q -p "/" list_queues name messages | awk -v Q="${q}" '$1==Q{print $2}')
  if [ "$actual" != "$expected" ]; then
    logerror "queue ${q} has ${actual} messages, expected ${expected}"
    exit 1
  fi
  log "  ${q}: ${actual} messages ✓"
done
log "all queues received the expected count — INIT-16875 sink flow verified"
