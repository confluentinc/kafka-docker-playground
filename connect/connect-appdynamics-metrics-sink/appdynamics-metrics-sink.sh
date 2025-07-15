#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

# Need to create the machine agent docker image https://github.com/Appdynamics/docker-machine-agent/blob/master/Dockerfile

if [ ! -f ${DIR}/docker-appdynamics-metrics/machine-agent.zip ]
then
     logerror "❌ ${DIR}/docker-appdynamics-metrics/ does not contain file machine-agent.zip"
     exit 1
fi

if test -z "$(docker images -q appdynamics-metrics:latest)"
then
     log "Building appdynamics-metrics docker image..it can take a while..."
     OLDDIR=$PWD
     cd ${DIR}/docker-appdynamics-metrics
     docker build -t appdynamics-metrics:latest .
     cd ${OLDDIR}
fi

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

log "Check logs"
docker exec -i appdynamics-metrics bash -c "cat /opt/appdynamics/machine-agent/logs/machine-agent.log"

log "Sending messages to topic appdynamics-metrics-topic"
playground topic produce -t appdynamics-metrics-topic << 'EOF'
{
  "fields": [
    {
      "name": "name",
      "type": "string"
    },
    {
      "name": "dimensions",
      "type": {
        "fields": [
          {
            "name": "aggregatorType",
            "type": "string"
          }
        ],
        "name": "dimensions",
        "type": "record"
      }
    },
    {
      "name": "values",
      "type": {
        "fields": [
          {
            "name": "doubleValue",
            "type": "double"
          }
        ],
        "name": "values",
        "type": "record"
      }
    }
  ],
  "name": "metric",
  "type": "record"
}
EOF

log "Creating AppDynamics Metrics sink connector"
playground connector create-or-update --connector appdynamics-metrics-sink  << EOF
{
     "connector.class": "io.confluent.connect.appdynamics.metrics.AppDynamicsMetricsSinkConnector",
     "tasks.max": "1",
     "topics": "appdynamics-metrics-topic",
     "machine.agent.host": "http://appdynamics-metrics",
     "machine.agent.port": "8090",
     "key.converter": "io.confluent.connect.avro.AvroConverter",
     "key.converter.schema.registry.url":"http://schema-registry:8081",
     "value.converter": "io.confluent.connect.avro.AvroConverter",
     "value.converter.schema.registry.url":"http://schema-registry:8081",
     "reporter.bootstrap.servers": "broker:9092",
     "reporter.error.topic.replication.factor": 1,
     "reporter.result.topic.replication.factor": 1,
     "behavior.on.error": "fail",
     "confluent.topic.bootstrap.servers": "broker:9092",
     "confluent.topic.replication.factor": "1"
}
EOF

sleep 5


log "Verify we have received the data in AMPS_Orders topic"
playground topic consume --topic AMPS_Orders --min-expected-messages 2 --timeout 60
