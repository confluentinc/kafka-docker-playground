#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if [ ! -z "$TAG_BASE" ] && version_gt $TAG_BASE "7.9.99" && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "1.9.9"
then
     logwarn "minimal supported connector version is 2.0.0 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

log "Generate data"
docker exec -i connect bash -c 'mkdir -p /tmp/data/input/ && mkdir -p /tmp/data/error/ && mkdir -p /tmp/data/finished/ && curl "https://raw.githubusercontent.com/jcustenborder/kafka-connect-spooldir/master/src/test/resources/com/github/jcustenborder/kafka/connect/spooldir/SpoolDirLineDelimitedSourceConnector/fix.json" > /tmp/data/input/fix.json'

log "Creating Line Delimited Spool Dir Source connector"
playground connector create-or-update --connector spool-dir  << EOF
{
     "tasks.max": "1",
     "connector.class": "com.github.jcustenborder.kafka.connect.spooldir.SpoolDirLineDelimitedSourceConnector",
     "input.file.pattern": ".*\\\\.json",
     "input.path": "/tmp/data/input",
     "error.path": "/tmp/data/error",
     "finished.path": "/tmp/data/finished",
     "halt.on.error": "false",
     "topic": "fix-topic",
     "schema.generation.enabled": "true"
}
EOF


sleep 5

log "Verify we have received the data in fix-topic topic"
playground topic consume --topic fix-topic --min-expected-messages 10 --timeout 60