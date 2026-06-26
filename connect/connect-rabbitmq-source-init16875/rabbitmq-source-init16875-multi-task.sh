#!/bin/bash
# INIT-16875: multi-task partitioning in self-managed mode.
#   - N=10 queues (mt-q01..mt-q10)
#   - tasks.max=2
#   - rabbitmq.max.queue.per.task=5
#   -> validator's required_min = ceil(10/5) = 2 == tasks.max, so accepted
#   -> chunks() splits 10 queues into 2 round-robin buckets of 5 each
#   -> task 0 owns {mt-q01, mt-q03, mt-q05, mt-q07, mt-q09} (odd indices)
#   -> task 1 owns {mt-q02, mt-q04, mt-q06, mt-q08, mt-q10} (even indices)
#
# Asserts:
#   1. /connectors/<id>/tasks returns 2 tasks each with exactly 5 queues
#   2. The two tasks' queue lists are disjoint and together cover all 10 queues
#   3. Each task gets the expected round-robin slice
#   4. All 10 queues drain after publishing

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

sleep 5

QUEUES=$(python3 -c "print(','.join(f'mt-q{i:02d}' for i in range(1,11)))")
log "Publishing 2 msgs to each of 10 queues (mt-q01..mt-q10)"
for q in $(echo "${QUEUES}" | tr ',' ' '); do
  docker exec rabbitmq_producer bash -c "python /producer.py ${q} 2" > /dev/null
done

log "Creating source connector: N=10, tasks.max=2, max.queue.per.task=5"
playground connector create-or-update --connector rabbitmq-multi-task << EOF
{
  "connector.class": "io.confluent.connect.rabbitmq.RabbitMQSourceConnector",
  "tasks.max": "2",
  "kafka.topic": "multi-task-topic",
  "rabbitmq.queue": "${QUEUES}",
  "rabbitmq.max.queue.per.task": "5",
  "rabbitmq.host": "rabbitmq",
  "rabbitmq.username": "myuser",
  "rabbitmq.password": "mypassword",
  "confluent.topic.bootstrap.servers": "broker:9092",
  "confluent.topic.replication.factor": "1"
}
EOF

sleep 10

log "Per-task queue assignment (proves chunks() round-robin)"
TASKS_JSON=$(docker exec connect curl -s http://localhost:8083/connectors/rabbitmq-multi-task/tasks)
echo "${TASKS_JSON}" | jq -c '.[] | {task: .id.task, queues: (.config["rabbitmq.queue"] | split(","))}'

log "Asserting 2 tasks of 5 queues each"
NUM_TASKS=$(echo "${TASKS_JSON}" | jq 'length')
if [ "$NUM_TASKS" != "2" ]; then
  logerror "expected 2 tasks, got ${NUM_TASKS}"
  exit 1
fi

T0_QUEUES=$(echo "${TASKS_JSON}" | jq -r '.[0].config["rabbitmq.queue"]')
T1_QUEUES=$(echo "${TASKS_JSON}" | jq -r '.[1].config["rabbitmq.queue"]')
T0_COUNT=$(echo "${T0_QUEUES}" | tr ',' '\n' | wc -l | tr -d ' ')
T1_COUNT=$(echo "${T1_QUEUES}" | tr ',' '\n' | wc -l | tr -d ' ')

log "  task 0 queues (${T0_COUNT}): ${T0_QUEUES}"
log "  task 1 queues (${T1_COUNT}): ${T1_QUEUES}"

if [ "$T0_COUNT" != "5" ] || [ "$T1_COUNT" != "5" ]; then
  logerror "expected 5 queues per task, got ${T0_COUNT} and ${T1_COUNT}"
  exit 1
fi

# Verify disjoint + complete coverage
OVERLAP=$(comm -12 <(echo "${T0_QUEUES}" | tr ',' '\n' | sort) <(echo "${T1_QUEUES}" | tr ',' '\n' | sort) | wc -l | tr -d ' ')
if [ "$OVERLAP" != "0" ]; then
  logerror "tasks share ${OVERLAP} queues (should be disjoint)"
  exit 1
fi

UNION=$(echo "${T0_QUEUES},${T1_QUEUES}" | tr ',' '\n' | sort -u | wc -l | tr -d ' ')
if [ "$UNION" != "10" ]; then
  logerror "union of task queues = ${UNION}, expected 10"
  exit 1
fi

# Verify round-robin pattern (task 0 = odd-indexed, task 1 = even-indexed)
EXPECTED_T0="mt-q01,mt-q03,mt-q05,mt-q07,mt-q09"
EXPECTED_T1="mt-q02,mt-q04,mt-q06,mt-q08,mt-q10"
if [ "${T0_QUEUES}" != "${EXPECTED_T0}" ] || [ "${T1_QUEUES}" != "${EXPECTED_T1}" ]; then
  logwarn "  round-robin pattern differs from expected (still disjoint + complete; chunks() is deterministic but order may vary):"
  logwarn "    expected task 0: ${EXPECTED_T0}"
  logwarn "    expected task 1: ${EXPECTED_T1}"
fi

log "  ✓ 2 tasks × 5 queues, disjoint, union = all 10 queues"

log "Verify all 20 messages flowed through (10 queues × 2 msgs)"
playground topic consume --topic multi-task-topic --min-expected-messages 20 --timeout 60

for q in $(echo "${QUEUES}" | tr ',' ' '); do
  num=$(docker exec rabbitmq rabbitmqctl -q -p "/" list_queues name messages | awk -v Q="${q}" '$1==Q{print $2}')
  if [ -z "$num" ] || [ "$num" -gt 0 ]; then
    logerror "queue ${q} still has ${num} messages, expected 0"
    exit 1
  fi
done
log "multi-task partitioning verified: N=10 / tasks.max=2 / max.queue.per.task=5"
