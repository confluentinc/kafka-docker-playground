#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if [ ! -z "$TAG_BASE" ] && version_gt $TAG_BASE "7.9.99" && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "10.5.99"
then
     logwarn "minimal supported connector version is 10.6.0 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

handle_aws_credentials

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

if [ "$(uname -m)" = "s390x" ]
then
    # Under QEMU emulation, broker startup is slow enough that Schema
    # Registry's own metadata lookup for `_schemas` (which Kafka
    # auto-creates with the default 'delete' cleanup policy) reliably wins
    # the race against Schema Registry's explicit create-with-'compact'
    # call, so it crash-loops on every fresh environment. Close the race by
    # forcing the correct policy as soon as the broker is reachable, before
    # letting Schema Registry retry.
    log "s390x: pre-empting the schema-registry/_schemas cleanup.policy race (see connect/CERTIFYING_S390X.md)"
    for i in $(seq 1 30)
    do
        if docker exec broker kafka-topics --bootstrap-server broker:9092 --list > /dev/null 2>&1
        then
            break
        fi
        sleep 2
    done
    docker exec broker kafka-topics --bootstrap-server broker:9092 --create --if-not-exists --topic _schemas --partitions 1 --replication-factor 1 --config cleanup.policy=compact > /dev/null 2>&1 || true
    docker exec broker kafka-configs --bootstrap-server broker:9092 --entity-type topics --entity-name _schemas --alter --add-config cleanup.policy=compact > /dev/null 2>&1 || true
    docker restart schema-registry > /dev/null 2>&1 || true
fi

AWS_BUCKET_NAME=${AWS_BUCKET_NAME:-pg-bucket-${USER}}
AWS_BUCKET_NAME=${AWS_BUCKET_NAME//[-.]/}


log "Create bucket <$AWS_BUCKET_NAME>, if required"
set +e
if [ "$AWS_REGION" == "us-east-1" ]
then
    aws s3api create-bucket --bucket $AWS_BUCKET_NAME --region $AWS_REGION
else
    aws s3api create-bucket --bucket $AWS_BUCKET_NAME --region $AWS_REGION --create-bucket-configuration LocationConstraint=$AWS_REGION
fi
set -e
log "Empty bucket <$AWS_BUCKET_NAME/$TAG>, if required"
set +e
aws s3 rm s3://$AWS_BUCKET_NAME/$TAG --recursive --region $AWS_REGION
set -e

log "Creating S3 Sink connector with bucket name <$AWS_BUCKET_NAME>"
playground connector create-or-update --connector s3-sink  << EOF
{
    "connector.class": "io.confluent.connect.s3.S3SinkConnector",
    "tasks.max": "1",
    "topics": "s3_topic",
    "s3.region": "$AWS_REGION",
    "s3.bucket.name": "$AWS_BUCKET_NAME",
    "topics.dir": "$TAG",
    "s3.part.size": "52428801",
    "flush.size": "3",
    "aws.access.key.id" : "$AWS_ACCESS_KEY_ID",
    "aws.secret.access.key": "$AWS_SECRET_ACCESS_KEY",
    "storage.class": "io.confluent.connect.s3.storage.S3Storage",
    "format.class": "io.confluent.connect.s3.format.avro.AvroFormat",
    "schema.compatibility": "NONE"
}
EOF

log "Sending messages to topic s3_topic"
playground topic produce -t s3_topic --nb-messages 10 --forced-value '{"f1":"value%g"}' << 'EOF'
{
  "type": "record",
  "name": "myrecord",
  "fields": [
    {
      "name": "f1",
      "type": "string"
    }
  ]
}
EOF

sleep 10

# log "Listing objects of in S3"
# aws s3api list-objects --bucket "$AWS_BUCKET_NAME"

log "Getting one of the avro files locally and displaying content with avro-tools"
aws s3 cp --only-show-errors s3://$AWS_BUCKET_NAME/$TAG/s3_topic/partition=0/s3_topic+0+0000000000.avro s3_topic+0+0000000000.avro

playground tools read-avro-file --file $PWD/s3_topic+0+0000000000.avro
rm -f s3_topic+0+0000000000.avro