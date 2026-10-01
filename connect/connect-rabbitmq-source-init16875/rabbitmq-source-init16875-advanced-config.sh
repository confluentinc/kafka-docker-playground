#!/bin/bash
# INIT-16875: exercise the new "advanced" knobs in self-managed mode where they're
# directly settable (no CC config-override allow-list gating):
#   - rabbitmq.max.queue.per.task=20      -> raises required-min so tasks.max=1 is
#                                            valid for N=20 queues (default would be 2)
#   - rabbitmq.prefetch.count=10          -> overrides the new default of 500
#   - rabbitmq.prefetch.global=false      -> per-consumer scope
#
# Asserts:
#   1. Validator accepts tasks.max=1 with N=20 (proves max.queue.per.task override)
#   2. Connector runs with exactly 1 task carrying all 20 queues
#   3. rabbitmqctl shows the channel's prefetch_count == 10
#   4. All 20 queues drain after a publish

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

sleep 5

QUEUES=$(python3 -c "print(','.join(f'qa{i:02d}' for i in range(1,21)))")
log "Publishing to 20 queues (qa01..qa20), 2 msgs each"
for q in $(echo "${QUEUES}" | tr ',' ' '); do
  docker exec rabbitmq_producer bash -c "python /producer.py ${q} 2" > /dev/null
done

log "Creating source connector: N=20 queues, tasks.max=1, max.queue.per.task=20, prefetch.count=10"
playground connector create-or-update --connector rabbitmq-source-advanced-config << EOF
{
  "connector.class": "io.confluent.connect.rabbitmq.RabbitMQSourceConnector",
  "tasks.max": "1",
  "kafka.topic": "advanced-config-topic",
  "rabbitmq.queue": "${QUEUES}",
  "rabbitmq.max.queue.per.task": "20",
  "rabbitmq.prefetch.count": "10",
  "rabbitmq.prefetch.global": "false",
  "rabbitmq.host": "rabbitmq",
  "rabbitmq.username": "myuser",
  "rabbitmq.password": "mypassword",
  "confluent.topic.bootstrap.servers": "broker:9092",
  "confluent.topic.replication.factor": "1"
}
EOF

sleep 10

log "Verify exactly 1 task with all 20 queues (proves max.queue.per.task=20 raises required-min)"
TASK_COUNT=$(docker exec connect curl -s http://localhost:8083/connectors/rabbitmq-source-advanced-config/tasks | jq 'length')
QUEUE_COUNT_T0=$(docker exec connect curl -s http://localhost:8083/connectors/rabbitmq-source-advanced-config/tasks | jq '.[0].config["rabbitmq.queue"] | split(",") | length')
log "  tasks: ${TASK_COUNT}, queues on task 0: ${QUEUE_COUNT_T0}"
if [ "$TASK_COUNT" != "1" ] || [ "$QUEUE_COUNT_T0" != "20" ]; then
  logerror "expected 1 task with 20 queues; got tasks=${TASK_COUNT}, queues=${QUEUE_COUNT_T0}"
  exit 1
fi

log "Verify channel prefetch_count=10 via rabbitmqctl"
# rabbitmqctl list_channels emits "Listing channels..." + "prefetch_count" column
# header + values. Grab the numeric line.
PREFETCH=$(docker exec rabbitmq rabbitmqctl list_channels prefetch_count 2>/dev/null | awk '/^[0-9]+$/{print; exit}')
log "  prefetch_count on connector channel: ${PREFETCH}"
if [ "$PREFETCH" != "10" ]; then
  logerror "expected prefetch_count=10 (override) but got '${PREFETCH}'"
  exit 1
fi

log "Verify queues drained (40 messages total flowed through tasks.max=1 with prefetch=10)"
playground topic consume --topic advanced-config-topic --min-expected-messages 40 --timeout 60

for q in $(echo "${QUEUES}" | tr ',' ' '); do
  num=$(docker exec rabbitmq rabbitmqctl -q -p "/" list_queues name messages | awk -v Q="${q}" '$1==Q{print $2}')
  if [ -z "$num" ] || [ "$num" -gt 0 ]; then
    logerror "queue ${q} still has ${num} messages, expected 0"
    exit 1
  fi
done

log "advanced-config verified: max.queue.per.task=20 + prefetch.count=10 both flow end-to-end"
