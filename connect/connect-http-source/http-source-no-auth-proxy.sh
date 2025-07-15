#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

source ${DIR}/../../scripts/utils.sh

if [ ! -z "$TAG_BASE" ] && version_gt $TAG_BASE "7.9.99" && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "0.1.99"
then
     logwarn "minimal supported connector version is 0.2.0 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.no-auth-proxy.yml"

log "Creating http-source connector"
playground connector create-or-update --connector http-source  << EOF
{
     "tasks.max": "1",
     "connector.class": "io.confluent.connect.http.HttpSourceConnector",
     "key.converter": "org.apache.kafka.connect.storage.StringConverter",
     "value.converter": "org.apache.kafka.connect.storage.StringConverter",
     "confluent.topic.bootstrap.servers": "broker:9092",
     "confluent.topic.replication.factor": "1",
     "url": "http://httpserver:8080/api/messages",
     "topic.name.pattern":"http-topic-\${entityName}",
     "entity.names": "messages",
     "http.offset.mode": "SIMPLE_INCREMENTING",
     "http.initial.offset": "1",
     "http.proxy.host": "nginx-proxy",
     "http.proxy.port": "8888"
}
EOF


sleep 3

log "Send a message to HTTP server"
curl -X PUT \
     -H "Content-Type: application/json" \
     --data '{"test":"value"}' \
     http://localhost:18080/api/messages | jq .


sleep 2

log "Verify we have received the data in http-topic-messages topic"
playground topic consume --topic http-topic-messages --min-expected-messages 1 --timeout 60
