#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if [ ! -z "$TAG_BASE" ] && version_gt $TAG_BASE "7.9.99" && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "1.5.11"
then
     logwarn "minimal supported connector version is 1.5.12 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

log "Creating Syslog Source connector"
playground connector create-or-update --connector syslog-source  << EOF
{
     "tasks.max": "1",
     "connector.class": "io.confluent.connect.syslog.SyslogSourceConnector",
     "syslog.port": "5454",
     "syslog.listener": "TCP",
     "confluent.license": "",
     "confluent.topic.bootstrap.servers": "broker:9092",
     "confluent.topic.replication.factor": "1"
}
EOF


sleep 10

log "Test with sample syslog-formatted message sent via netcat"
echo "<34>1 2003-10-11T22:14:15.003Z mymachine.example.com su - ID47 - Your refrigerator is running" | docker run -i --rm --network=host subfuzion/netcat -v -w 0 localhost 5454

sleep 5

log "Verify we have received the data in syslog topic"
playground topic consume --topic syslog --min-expected-messages 1 --timeout 60