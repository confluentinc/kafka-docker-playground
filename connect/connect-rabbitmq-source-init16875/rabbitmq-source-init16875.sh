#!/bin/bash
# INIT-16875 source-side functional test for self-managed Connect:
#   - 4 RabbitMQ queues (q1,q2,q3,q4) with `tasks.max=2` so the partitioner
#     splits them 2-per-task using the round-robin chunker.
#   - Partial `rabbitmq.queue.topic.map`: q1->topic-a, q2->topic-b.
#     q3 + q4 fall back to `kafka.topic=topic-fallback`.
#   - Verifies messages land in the mapped + fallback topics, prints the
#     per-task `rabbitmq.queue` assignment via the Connect REST API to
#     confirm INIT-16875 task partitioning.

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

sleep 5

for q in q1 q2 q3 q4; do
  log "Send 5 messages to RabbitMQ queue ${q}"
  docker exec rabbitmq_producer bash -c "python /producer.py ${q} 5"
done

log "Creating INIT-16875 RabbitMQ Source connector (4 queues, tasks.max=2, partial queue->topic map)"
playground connector create-or-update --connector rabbitmq-source-init16875 << EOF
{
  "connector.class": "io.confluent.connect.rabbitmq.RabbitMQSourceConnector",
  "tasks.max": "2",
  "kafka.topic": "topic-fallback",
  "rabbitmq.queue": "q1,q2,q3,q4",
  "rabbitmq.queue.topic.map": "{\"q1\":\"topic-a\",\"q2\":\"topic-b\"}",
  "rabbitmq.host": "rabbitmq",
  "rabbitmq.username": "myuser",
  "rabbitmq.password": "mypassword",
  "confluent.topic.bootstrap.servers": "broker:9092",
  "confluent.topic.replication.factor": "1"
}
EOF

sleep 10

log "Per-task queue assignment (proves INIT-16875 partitioning)"
docker exec connect curl -s http://localhost:8083/connectors/rabbitmq-source-init16875/tasks \
  | jq -c '.[] | {task: .id.task, queues: (.config["rabbitmq.queue"] | split(",")), topic_map: .config["rabbitmq.queue.topic.map"]}'

log "Verify mapped routes: q1 -> topic-a (expect 5)"
playground topic consume --topic topic-a --min-expected-messages 5 --timeout 60

log "Verify mapped routes: q2 -> topic-b (expect 5)"
playground topic consume --topic topic-b --min-expected-messages 5 --timeout 60

log "Verify fallback route: q3 + q4 -> topic-fallback (expect 10)"
playground topic consume --topic topic-fallback --min-expected-messages 10 --timeout 60

log "Asserting all RabbitMQ queues are drained"
for q in q1 q2 q3 q4; do
  num_messages=$(docker exec rabbitmq rabbitmqctl -q -p "/" list_queues name messages | awk -v Q="${q}" '$1==Q{print $2}')
  if [ -z "$num_messages" ] || [ "$num_messages" -gt 0 ]; then
    logerror "queue ${q} still has ${num_messages} messages, expected 0"
    exit 1
  fi
done
log "all queues drained successfully — INIT-16875 source flow verified"
