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

export AWS_CREDENTIALS_FILE_NAME=$HOME/.aws/credentials-with-assuming-iam-role
if [ ! -f $AWS_CREDENTIALS_FILE_NAME ]
then
     logerror "❌ $AWS_CREDENTIALS_FILE_NAME is not set"
     exit 1
fi

handle_aws_credentials

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.with-assuming-iam-role.yml"

TIMESTAMP=`date +%s000`
log "Sending messages to topic cloudwatch-metrics-topic"
playground topic produce --topic cloudwatch-metrics-topic --nb-messages 1 --key "key1" --forced-value "{\"name\" : \"test_meter\",\"type\" : \"meter\", \"timestamp\" : $TIMESTAMP, \"dimensions\" : {\"dimensions1\" : \"InstanceID\",\"dimensions2\" : \"i-aaba32d4\"},\"values\" : {\"count\" : 32423.0,\"oneMinuteRate\" : 342342.2,\"fiveMinuteRate\" : 34234.2,\"fifteenMinuteRate\" : 2123123.1,\"meanRate\" : 2312312.1}}" << 'EOF'
{
  "name": "myMetric",
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
            "name": "dimensions1",
            "type": "string"
          },
          {
            "name": "dimensions2",
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
            "name": "count",
            "type": "double"
          },
          {
            "name": "oneMinuteRate",
            "type": "double"
          },
          {
            "name": "fiveMinuteRate",
            "type": "double"
          },
          {
            "name": "fifteenMinuteRate",
            "type": "double"
          },
          {
            "name": "meanRate",
            "type": "double"
          }
        ]
      }
    }
  ]
}
EOF

CLOUDWATCH_METRICS_URL="https://monitoring.$AWS_REGION.amazonaws.com"

log "Creating AWS CloudWatch metrics Sink connector"
playground connector create-or-update --connector aws-cloudwatch-metrics-sink  << EOF
{
    "tasks.max": "1",
    "topics": "cloudwatch-metrics-topic",
    "connector.class": "io.confluent.connect.aws.cloudwatch.metrics.AwsCloudWatchMetricsSinkConnector",
    "value.converter": "io.confluent.connect.avro.AvroConverter",
    "value.converter.schema.registry.url": "http://schema-registry:8081",
    "aws.cloudwatch.metrics.url": "$CLOUDWATCH_METRICS_URL",
    "aws.cloudwatch.metrics.namespace": "service-namespace",
    "behavior.on.malformed.metric": "FAIL",
    "confluent.license": "",
    "confluent.topic.bootstrap.servers": "broker:9092",
    "confluent.topic.replication.factor": "1"
}
EOF

sleep 10

log "View the metrics being produced to Amazon CloudWatch"
aws cloudwatch list-metrics --namespace service-namespace --region $AWS_REGION > /tmp/result.log  2>&1
cat /tmp/result.log
grep "test_meter_fifteenMinuteRate" /tmp/result.log
