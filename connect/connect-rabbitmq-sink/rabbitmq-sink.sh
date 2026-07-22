#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if [ ! -z "$TAG_BASE" ] && version_gt $TAG_BASE "7.9.99" && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "1.7.99"
then
     logwarn "minimal supported connector version is 1.8.0 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"


log "Create RabbitMQ exchange, queue and binding"
docker exec -i rabbitmq rabbitmqadmin -u myuser -p mypassword -V / declare exchange name=exchange1 type=direct
docker exec -i rabbitmq rabbitmqadmin -u myuser -p mypassword -V / declare queue name=queue1 durable=true
docker exec -i rabbitmq rabbitmqadmin -u myuser -p mypassword -V / declare binding source=exchange1 destination=queue1 routing_key=rkey1


log "Sending messages to topic rabbitmq-messages"
playground topic produce -t rabbitmq-messages --nb-messages 10 << 'EOF'
%g
EOF

log "Creating RabbitMQ Sink connector"
playground connector create-or-update --connector rabbitmq-sink  << EOF
{
     "connector.class" : "io.confluent.connect.rabbitmq.sink.RabbitMQSinkConnector",
     "tasks.max" : "1",
     "topics": "rabbitmq-messages",
     "key.converter": "org.apache.kafka.connect.storage.StringConverter",
     "value.converter": "org.apache.kafka.connect.converters.ByteArrayConverter",
     "rabbitmq.queue" : "myqueue",
     "rabbitmq.host" : "rabbitmq",
     "rabbitmq.username" : "myuser",
     "rabbitmq.password" : "mypassword",
     "rabbitmq.exchange": "exchange1",
     "rabbitmq.routing.key": "rkey1",
     "rabbitmq.delivery.mode": "PERSISTENT",
     "confluent.topic.bootstrap.servers": "broker:9092",
     "confluent.topic.replication.factor": "1"
}
EOF


sleep 5

log "Check messages received in RabbitMQ"
docker exec -i rabbitmq rabbitmqadmin -u myuser -p mypassword get queue=queue1 count=10 > /tmp/result.log  2>&1
cat /tmp/result.log
grep "rkey1" /tmp/result.log

####################################################################################
# topic -> queue mapping with fallback.
#   3 topics (topic-a, topic-b, topic-c) x 5 messages
#   map: topic-a->qa, topic-b->qb ; topic-c falls back to amq.direct/fallback-rk -> qc-fallback
####################################################################################
log "Provisioning queues qa, qb, and qc-fallback (bound to amq.direct/fallback-rk)"
docker exec -i rabbitmq rabbitmqadmin -u myuser -p mypassword -V / declare queue name=qa durable=true
docker exec -i rabbitmq rabbitmqadmin -u myuser -p mypassword -V / declare queue name=qb durable=true
docker exec -i rabbitmq rabbitmqadmin -u myuser -p mypassword -V / declare queue name=qc-fallback durable=true
docker exec -i rabbitmq rabbitmqadmin -u myuser -p mypassword -V / declare binding source=amq.direct destination=qc-fallback routing_key=fallback-rk

log "Producing 5 messages to each of topic-a, topic-b, topic-c"
for t in topic-a topic-b topic-c; do
  playground topic produce -t ${t} --nb-messages 5 << 'EOF'
%g
EOF
done

log "Creating sink connector (partial topic->queue map + fallback exchange)"
playground connector create-or-update --connector rabbitmq-sink-map << EOF
{
  "connector.class": "io.confluent.connect.rabbitmq.sink.RabbitMQSinkConnector",
  "tasks.max": "1",
  "topics": "topic-a,topic-b,topic-c",
  "key.converter": "org.apache.kafka.connect.storage.StringConverter",
  "value.converter": "org.apache.kafka.connect.converters.ByteArrayConverter",
  "rabbitmq.topic.queue.map": "{\"topic-a\":\"qa\",\"topic-b\":\"qb\"}",
  "rabbitmq.exchange": "amq.direct",
  "rabbitmq.routing.key": "fallback-rk",
  "rabbitmq.delivery.mode": "PERSISTENT",
  "rabbitmq.host": "rabbitmq",
  "rabbitmq.username": "myuser",
  "rabbitmq.password": "mypassword",
  "confluent.topic.bootstrap.servers": "broker:9092",
  "confluent.topic.replication.factor": "1"
}
EOF

sleep 15

log "Asserting queue depths: qa=5 (topic-a), qb=5 (topic-b), qc-fallback=5 (topic-c fallback)"
for pair in "qa 5" "qb 5" "qc-fallback 5"; do
  q=$(echo "$pair" | awk '{print $1}')
  expected=$(echo "$pair" | awk '{print $2}')
  actual=$(docker exec rabbitmq rabbitmqctl -q -p "/" list_queues name messages | awk -v Q="${q}" '$1==Q{print $2}')
  if [ "$actual" != "$expected" ]; then
    logerror "queue ${q} has '${actual}' messages, expected ${expected}"
    exit 1
  fi
  log "  ${q}: ${actual} messages"
done
log "topic->queue mapping scenario verified (map + fallback)"