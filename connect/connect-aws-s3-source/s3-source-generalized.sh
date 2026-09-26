#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if ! version_gt $CONNECTOR_TAG "1.9.9"; then
    # skipped
    logwarn "skipped as it requires connector version 2.0.0"
    exit 111
fi

if ! version_gt $TAG_BASE "5.9.99" && version_gt $CONNECTOR_TAG "1.9.9"
then
    logwarn "connector version >= 2.0.0 do not support CP versions < 6.0.0"
    exit 111
fi

if [ ! -z "$TAG_BASE" ] && version_gt $TAG_BASE "7.9.99" && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "2.6.15"
then
     logwarn "minimal supported connector version is 2.6.16 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

handle_aws_credentials

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.generalized.yml"

AWS_BUCKET_NAME=pg-bucket-${USER}
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
log "Empty bucket <$AWS_BUCKET_NAME/quickstart>, if required"
set +e
aws s3 rm s3://$AWS_BUCKET_NAME/quickstart --recursive --region $AWS_REGION
set -e


log "Copy generalized.quickstart.json to bucket $AWS_BUCKET_NAME/quickstart"
aws s3 cp generalized.quickstart.json s3://$AWS_BUCKET_NAME/quickstart/generalized.quickstart.json

log "Creating Generalized S3 Source connector with bucket name <$AWS_BUCKET_NAME>"
playground connector create-or-update --connector s3-source-generalized  << EOF
{
    "tasks.max": "1",
    "connector.class": "io.confluent.connect.s3.source.S3SourceConnector",
    "s3.region": "$AWS_REGION",
    "s3.bucket.name": "$AWS_BUCKET_NAME",
    "aws.access.key.id" : "$AWS_ACCESS_KEY_ID",
    "aws.secret.access.key": "$AWS_SECRET_ACCESS_KEY",
    "format.class": "io.confluent.connect.s3.format.json.JsonFormat",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "confluent.license": "",
    "mode": "GENERIC",
    "topics.dir": "quickstart",
    "topic.regex.list": "quick-start-topic:.*",
    "confluent.topic.bootstrap.servers": "broker:9092",
    "confluent.topic.replication.factor": "1",
    "errors.tolerance": "all",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true",
    "file.metadata.headers.enable": "true"
}
EOF


log "Verifying topic quick-start-topic"
playground topic consume --topic quick-start-topic --min-expected-messages 9 --timeout 60

log "Verifying source.file.* record headers are present"
# Re-consume one record directly via kafka-console-consumer so we can capture
# headers and grep them. The playground consume above already prints headers
# but its output isn't easily captured.
sample_record=$(docker exec connect kafka-console-consumer \
    --bootstrap-server broker:9092 \
    --topic quick-start-topic \
    --from-beginning \
    --max-messages 1 \
    --property print.headers=true \
    --property headers.separator=, \
    --timeout-ms 30000 2>&1 || true)

log "Sample record (with headers):"
echo "$sample_record"

missing=()
for header in source.file.name source.file.path source.file.last_modified source.file.size; do
    if ! grep -q "${header}:" <<< "$sample_record"; then
        missing+=("$header")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    logerror "Missing source.file.* headers: ${missing[*]}"
    exit 1
fi

# Spot-check the values.
file_name=$(grep -oE "source\.file\.name:[^,|]*" <<< "$sample_record" | head -1 | cut -d: -f2-)
file_path=$(grep -oE "source\.file\.path:[^,|]*" <<< "$sample_record" | head -1 | cut -d: -f2-)
file_size=$(grep -oE "source\.file\.size:[^,|]*" <<< "$sample_record" | head -1 | cut -d: -f2-)
file_last_modified=$(grep -oE "source\.file\.last_modified:[^,|]*" <<< "$sample_record" | head -1 | cut -d: -f2-)

log "source.file.name           = $file_name"
log "source.file.path           = $file_path"
log "source.file.size           = $file_size"
log "source.file.last_modified  = $file_last_modified"

[[ "$file_name" == "generalized.quickstart.json" ]] \
    || { logerror "expected source.file.name=generalized.quickstart.json, got '$file_name'"; exit 1; }
[[ "$file_path" == "quickstart/generalized.quickstart.json" ]] \
    || { logerror "expected source.file.path=quickstart/generalized.quickstart.json, got '$file_path'"; exit 1; }
[[ "$file_size" =~ ^[0-9]+$ ]] && [ "$file_size" -gt 0 ] \
    || { logerror "expected source.file.size to be a positive integer, got '$file_size'"; exit 1; }
[[ "$file_last_modified" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]] \
    || { logerror "expected source.file.last_modified to be ISO-8601 instant, got '$file_last_modified'"; exit 1; }

log "All four source.file.* headers verified"
