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

sleep 5

log "Send message to RabbitMQ in myqueue"
docker exec rabbitmq_producer bash -c "python /producer.py myqueue 5"

log "Creating RabbitMQ Source connector"
playground connector create-or-update --connector rabbitmq-source  << EOF
{
     "connector.class" : "io.confluent.connect.rabbitmq.RabbitMQSourceConnector",
     "tasks.max" : "1",
     "kafka.topic" : "rabbitmq",
     "rabbitmq.queue" : "myqueue",
     "rabbitmq.host" : "rabbitmq",
     "rabbitmq.username" : "myuser",
     "rabbitmq.password" : "mypassword",
     "confluent.topic.bootstrap.servers": "broker:9092",
     "confluent.topic.replication.factor": "1"
}
EOF


sleep 5

log "Verify we have received the data in rabbitmq topic"
playground topic consume --topic rabbitmq --min-expected-messages 5 --timeout 60

#log "Consume messages in RabbitMQ"
#docker exec -i rabbitmq_consumer bash -c "python /consumer.py myqueue"

####################################################################################
# queue -> topic mapping, task partitioning, and consumer modes.
####################################################################################

# Scenario A - dedicated mode (default): queue->topic map + fallback, with task
# partitioning bounded by rabbitmq.max.queue.per.task.
#   4 queues, tasks.max=2, max.queue.per.task=2
#   map: q1->topic-a, q2->topic-b ; q3,q4 fall back to kafka.topic=topic-fallback
log "[A] dedicated: publishing 5 messages to each of q1..q4"
for q in q1 q2 q3 q4; do
  docker exec rabbitmq_producer bash -c "python /producer.py ${q} 5"
done

log "[A] creating source connector (4 queues, tasks.max=2, max.queue.per.task=2, partial map)"
playground connector create-or-update --connector rabbitmq-source-map << EOF
{
  "connector.class": "io.confluent.connect.rabbitmq.RabbitMQSourceConnector",
  "tasks.max": "2",
  "kafka.topic": "topic-fallback",
  "rabbitmq.queue": "q1,q2,q3,q4",
  "rabbitmq.queue.topic.map": "{\"q1\":\"topic-a\",\"q2\":\"topic-b\"}",
  "rabbitmq.max.queue.per.task": "2",
  "rabbitmq.host": "rabbitmq",
  "rabbitmq.username": "myuser",
  "rabbitmq.password": "mypassword",
  "confluent.topic.bootstrap.servers": "broker:9092",
  "confluent.topic.replication.factor": "1"
}
EOF

log "[A] waiting for tasks to subscribe"
sleep 10

log "[A] per-task queue assignment (informational)"
docker exec connect curl -s http://localhost:8083/connectors/rabbitmq-source-map/tasks \
  | jq -c '.[] | {task: .id.task, queues: (.config["rabbitmq.queue"] | split(","))}'

# dedicated mode -> each queue is consumed by exactly ONE task
log "[A] asserting each queue has exactly 1 consumer (dedicated topology)"
for q in q1 q2 q3 q4; do
  c=$(docker exec rabbitmq rabbitmqctl -q -p "/" list_queues name consumers | awk -v Q="${q}" '$1==Q{print $2}')
  if [ "$c" != "1" ]; then
    logerror "[A] queue ${q} has '${c}' consumers, expected 1 (dedicated mode)"
    exit 1
  fi
done

log "[A] verify routing: q1 -> topic-a (5), q2 -> topic-b (5), q3+q4 -> topic-fallback (10)"
playground topic consume --topic topic-a --min-expected-messages 5 --timeout 60
playground topic consume --topic topic-b --min-expected-messages 5 --timeout 60
playground topic consume --topic topic-fallback --min-expected-messages 10 --timeout 60

# Scenario B - shared mode: every task subscribes to every queue. Contrast with
# dedicated: each queue should have tasks.max consumers, not 1. Per-queue ordering
# is intentionally NOT preserved in this mode.
# Publish BEFORE creating the connector so the queues exist (fail-fast default).
log "[B] shared: publishing 5 messages to each of s1,s2 (also declares the queues)"
docker exec rabbitmq_producer bash -c "python /producer.py s1 5"
docker exec rabbitmq_producer bash -c "python /producer.py s2 5"

log "[B] creating source connector (2 queues, tasks.max=2, consumer.mode=shared)"
playground connector create-or-update --connector rabbitmq-source-shared << EOF
{
  "connector.class": "io.confluent.connect.rabbitmq.RabbitMQSourceConnector",
  "tasks.max": "2",
  "kafka.topic": "rabbitmq-shared",
  "rabbitmq.queue": "s1,s2",
  "rabbitmq.queue.consumer.mode": "shared",
  "rabbitmq.host": "rabbitmq",
  "rabbitmq.username": "myuser",
  "rabbitmq.password": "mypassword",
  "confluent.topic.bootstrap.servers": "broker:9092",
  "confluent.topic.replication.factor": "1"
}
EOF

log "[B] waiting for tasks to subscribe"
sleep 10

log "[B] asserting each queue has tasks.max (2) consumers (shared topology)"
for q in s1 s2; do
  c=$(docker exec rabbitmq rabbitmqctl -q -p "/" list_queues name consumers | awk -v Q="${q}" '$1==Q{print $2}')
  if [ "$c" != "2" ]; then
    logerror "[B] queue ${q} has '${c}' consumers, expected 2 (shared mode)"
    exit 1
  fi
done

log "[B] verify all 10 messages (s1:5 + s2:5) reached topic rabbitmq-shared"
playground topic consume --topic rabbitmq-shared --min-expected-messages 10 --timeout 60

log "queue->topic mapping scenarios verified (dedicated map/partitioning + shared mode)"