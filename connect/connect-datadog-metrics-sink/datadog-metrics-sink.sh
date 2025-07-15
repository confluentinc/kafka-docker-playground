#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if [ ! -z "$TAG_BASE" ] && version_gt $TAG_BASE "7.9.99" && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "2.0.3"
then
     logwarn "minimal supported connector version is 2.0.4 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

DD_API_KEY=${DD_API_KEY:-$1}
DD_APP_KEY=${DD_APP_KEY:-$2}

if [ -z "$DD_API_KEY" ]
then
     logerror "DD_API_KEY is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

if [ -z "$DD_APP_KEY" ]
then
     logerror "DD_APP_KEY is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

if test -z "$(docker images -q dogshell:latest)"
then
     log "Building dogshell docker image.."
     OLDDIR=$PWD
     cd ${DIR}/docker-dogshell
     docker build -t dogshell:latest .
     cd ${OLDDIR}
fi

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

log "Sending messages to topic datadog-metrics-topic"
TIMESTAMP=`date +%s`
playground topic produce -t datadog-metrics-topic --nb-messages 1 --forced-value="{\"name\":\"perf.metric\", \"type\":\"rate\",\"timestamp\": $TIMESTAMP, \"dimensions\": {\"host\": \"metric.host1\", \"interval\": 1, \"tag1\": \"testing-data\"},\"values\": {\"doubleValue\": 5.639623848362502}}" << 'EOF'
{
  "name": "metric",
  "type": "record",
  "fields": [
    {
      "name": "name",
      "type": "string"
    },
    {
      "name": "type",
      "type": "string"
    },
    {
      "name": "timestamp",
      "type": "long"
    },
    {
      "name": "dimensions",
      "type": {
        "name": "dimensions",
        "type": "record",
        "fields": [
          {
            "name": "host",
            "type": "string"
          },
          {
            "name": "interval",
            "type": "int"
          },
          {
            "name": "tag1",
            "type": "string"
          }
        ]
      }
    },
    {
      "name": "values",
      "type": {
        "name": "values",
        "type": "record",
        "fields": [
          {
            "name": "doubleValue",
            "type": "double"
          }
        ]
      }
    }
  ]
}
EOF

log "Creating Datadog metrics sink connector"
playground connector create-or-update --connector datadog-metrics-sink  << EOF
{
     "connector.class": "io.confluent.connect.datadog.metrics.DatadogMetricsSinkConnector",
     "tasks.max": "1",
     "key.converter":"org.apache.kafka.connect.storage.StringConverter",
     "value.converter":"io.confluent.connect.avro.AvroConverter",
     "value.converter.schema.registry.url":"http://schema-registry:8081",
     "confluent.topic.bootstrap.servers": "broker:9092",
     "confluent.topic.replication.factor":1,
     "datadog.api.key": "$DD_API_KEY",
     "datadog.domain": "COM",
     "reporter.bootstrap.servers": "broker:9092",
     "reporter.error.topic.name": "error-responses",
     "reporter.error.topic.replication.factor": 1,
     "reporter.result.topic.name": "success-responses",
     "reporter.result.topic.replication.factor": 1,
     "behavior.on.error": "fail",
     "topics": "datadog-metrics-topic"
}
EOF

sleep 20

log "Make sure perf.metric is present in Datadog"
docker run -e DOGSHELL_API_KEY=$DD_API_KEY -e DOGSHELL_APP_KEY=$DD_APP_KEY dogshell:latest search query perf.metric > /tmp/result.log  2>&1
cat /tmp/result.log
grep "perf.metric" /tmp/result.log
