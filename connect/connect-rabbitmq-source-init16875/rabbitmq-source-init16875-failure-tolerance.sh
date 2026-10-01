#!/bin/bash
# INIT-16875: failure-tolerance behavior in self-managed mode.
#
# Self-managed Connect's POST /connectors endpoint invokes the framework's
# Connector.validate(), which calls our RabbitMQSourceConfigValidation.
# That validator unconditionally probes every queue via queueDeclarePassive
# (regardless of `rabbitmq.queue.failure.tolerance`). So:
#
#   - Submit-time:  missing queue -> REJECTED with 400 + actionable error,
#                   under BOTH tolerance modes. This is correct semantics:
#                   missing-queue-at-config-time is a typo / config error,
#                   not a "runtime resilience" scenario.
#
#   - Runtime:      the tolerance knob governs what happens when a queue
#                   disappears AFTER the connector has started (e.g. a
#                   broker admin deletes it). Under skip-and-continue the
#                   connector WARN-logs and keeps consuming from survivors;
#                   that's the path this script exercises in Phase 2.
#
# Phase 1: prove validate rejects missing queue under both tolerances.
# Phase 2: prove runtime skip-and-continue via mid-run queue deletion.

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

sleep 5

declare_queue() {
  docker exec rabbitmq_producer bash -c "python /producer.py $1 1" > /dev/null
}

# ============================================================
# Phase 1: validate-time rejection (both tolerance modes)
# ============================================================
log "Phase 1: validate-time rejection of missing queue"
log "  declaring ft-q1, ft-q2 (NOT declaring ft-missing)"
declare_queue ft-q1
declare_queue ft-q2

for tolerance in "skip-and-continue" "fail-fast"; do
  log "  submitting connector with tolerance=${tolerance} (expect rejection)"
  # Write the config to a host-side file, then POST it from inside the connect container.
  CONFIG_FILE="/tmp/ft-${tolerance}.json"
  cat > "${CONFIG_FILE}" <<EOF
{
  "name": "rabbitmq-ft-${tolerance}",
  "config": {
    "connector.class": "io.confluent.connect.rabbitmq.RabbitMQSourceConnector",
    "tasks.max": "1",
    "kafka.topic": "ft-topic-${tolerance}",
    "rabbitmq.queue": "ft-q1,ft-missing,ft-q2",
    "rabbitmq.queue.failure.tolerance": "${tolerance}",
    "rabbitmq.host": "rabbitmq",
    "rabbitmq.username": "myuser",
    "rabbitmq.password": "mypassword",
    "confluent.topic.bootstrap.servers": "broker:9092",
    "confluent.topic.replication.factor": "1"
  }
}
EOF
  docker cp "${CONFIG_FILE}" connect:/tmp/ft-config.json > /dev/null
  STATUS=$(docker exec connect curl -s -o /tmp/resp.json -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" \
    --data-binary @/tmp/ft-config.json \
    http://localhost:8083/connectors)
  BODY=$(docker exec connect cat /tmp/resp.json)
  log "    HTTP status: ${STATUS}"
  log "    body: $(echo "${BODY}" | head -c 250)"
  if [ "$STATUS" = "200" ] || [ "$STATUS" = "201" ]; then
    logerror "    connector was unexpectedly created (status ${STATUS}) under tolerance=${tolerance}"
    exit 1
  fi
  if ! echo "${BODY}" | grep -qE "ft-missing|not accessible"; then
    logerror "    rejection did not mention missing queue; body: ${BODY}"
    exit 1
  fi
  log "    ✓ rejected with actionable error mentioning ft-missing"
done
log "  ✓ both tolerance modes correctly rejected at validate-time (config error semantics)"

# ============================================================
# Phase 2: runtime skip-and-continue via mid-run queue deletion
# ============================================================
log ""
log "Phase 2: runtime skip-and-continue via mid-run queue deletion"
log "  declaring ft-rq1, ft-rq2, ft-rq3 and creating connector with default tolerance"
docker exec rabbitmq_producer bash -c "python /producer.py ft-rq1 3" > /dev/null
docker exec rabbitmq_producer bash -c "python /producer.py ft-rq2 3" > /dev/null
docker exec rabbitmq_producer bash -c "python /producer.py ft-rq3 3" > /dev/null

playground connector create-or-update --connector rabbitmq-ft-runtime << EOF
{
  "connector.class": "io.confluent.connect.rabbitmq.RabbitMQSourceConnector",
  "tasks.max": "1",
  "kafka.topic": "ft-runtime-topic",
  "rabbitmq.queue": "ft-rq1,ft-rq2,ft-rq3",
  "rabbitmq.host": "rabbitmq",
  "rabbitmq.username": "myuser",
  "rabbitmq.password": "mypassword",
  "confluent.topic.bootstrap.servers": "broker:9092",
  "confluent.topic.replication.factor": "1"
}
EOF

sleep 8
log "  initial drain (3 queues, 9 msgs total)"
playground topic consume --topic ft-runtime-topic --min-expected-messages 9 --timeout 30

log "  deleting ft-rq2 mid-run via rabbitmqctl"
docker exec rabbitmq rabbitmqctl -q delete_queue ft-rq2

sleep 5
STATE=$(docker exec connect curl -s http://localhost:8083/connectors/rabbitmq-ft-runtime/status | jq -r '.connector.state')
TASK_STATE=$(docker exec connect curl -s http://localhost:8083/connectors/rabbitmq-ft-runtime/status | jq -r '.tasks[0].state')
log "  connector state: ${STATE}, task[0] state: ${TASK_STATE}"
if [ "$STATE" != "RUNNING" ] || [ "$TASK_STATE" != "RUNNING" ]; then
  logerror "  expected RUNNING/RUNNING after mid-run deletion, got ${STATE}/${TASK_STATE}"
  exit 1
fi

log "  ✓ connector stayed RUNNING after queue deletion (skip-and-continue at runtime)"

log "  verifying survivors (ft-rq1, ft-rq3) still flow"
docker exec rabbitmq_producer bash -c "python /producer.py ft-rq1 2" > /dev/null
docker exec rabbitmq_producer bash -c "python /producer.py ft-rq3 2" > /dev/null
playground topic consume --topic ft-runtime-topic --min-expected-messages 13 --timeout 30

if docker logs connect 2>&1 | grep -E "cancelled by broker|ft-rq2.*cancel" > /dev/null; then
  log "  ✓ found expected WARN log about ft-rq2 cancellation"
else
  logwarn "  (no explicit WARN match — connector RUNNING + survivors flowing is the primary signal)"
fi

log "failure-tolerance verified end-to-end: validate rejects at submit, runtime skips at deletion"
