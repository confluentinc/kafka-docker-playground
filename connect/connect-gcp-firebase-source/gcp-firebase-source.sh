#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if [ ! -z "$TAG_BASE" ] && version_gt $TAG_BASE "7.9.99" && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "1.2.6"
then
     logwarn "minimal supported connector version is 1.2.7 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

if [ -z "$GCP_PROJECT" ]
then
     logerror "GCP_PROJECT is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

cd ../../connect/connect-gcp-firebase-source
GCP_KEYFILE="${PWD}/keyfile.json"
if [ ! -f ${GCP_KEYFILE} ] && [ -z "$GCP_KEYFILE_CONTENT" ]
then
     logerror "❌ either the file ${GCP_KEYFILE} is not present or environment variable GCP_KEYFILE_CONTENT is not set!"
     exit 1
else 
    if [ -f ${GCP_KEYFILE} ]
    then
        GCP_KEYFILE_CONTENT=$(cat keyfile.json | jq -aRs . | sed 's/^"//' | sed 's/"$//')
    else
        log "Creating ${GCP_KEYFILE} based on environment variable GCP_KEYFILE_CONTENT"
        echo -e "$GCP_KEYFILE_CONTENT" | sed 's/\\"/"/g' > ${GCP_KEYFILE}
    fi
fi
cd -

# s390x: andreysenov/firebase-tools publishes no s390x image (amd64/arm64 only). Run emulated under
# QEMU the firebase CLI cannot get an OAuth token (TLS fails with a bad record MAC; with
# OPENSSL_ia32cap=0x0 Google answers 400 invalid_request). The same token exchange works natively on
# the s390x host, so on s390x run the CLI natively: node:20-slim has an s390x manifest and
# firebase-tools supports Node >= 20. Other architectures keep using andreysenov/firebase-tools.
FIREBASE_IMAGE="andreysenov/firebase-tools"
FIREBASE_CMD="firebase"
FIREBASE_DOCKER_ARGS=""
if [ "$(uname -m)" = "s390x" ]; then
  FIREBASE_IMAGE="node:20-slim"
  FIREBASE_CMD="npx --yes firebase-tools@15.37.0"
  # named volume keeps the npm cache between the CLI invocations of one test
  FIREBASE_DOCKER_ARGS="-e npm_config_cache=/npm-cache -e npm_config_update_notifier=false -v kdp-firebase-npm-cache:/npm-cache"
fi


# the amd64 pipeline (upstream KDP) selects the database region via the GCP_FIREBASE_REGION env var; this fork only read $1,
# so on s390x the connector connected to a non-existent europe-west1 instance. Accept both: env var, then argument, then default.
GCP_FIREBASE_REGION=${GCP_FIREBASE_REGION:-${1:-europe-west1}}
if [ "$GCP_FIREBASE_REGION" == "us-central1" ]
then
     GCP_FIREBASE_DATABASE_REFERENCE="https://${GCP_PROJECT}.firebaseio.com/musicBlog"
else
     GCP_FIREBASE_DATABASE_REFERENCE="https://${GCP_PROJECT}-default-rtdb.${GCP_FIREBASE_REGION}.firebasedatabase.app/musicBlog"
fi

log "Removing all data"
docker run -p 9005:9005 -v $PWD/../../connect/connect-gcp-firebase-source/keyfile.json:/tmp/keyfile.json:z -e GOOGLE_APPLICATION_CREDENTIALS="/tmp/keyfile.json" -e PROJECT=$GCP_PROJECT ${FIREBASE_DOCKER_ARGS} -i ${FIREBASE_IMAGE} ${FIREBASE_CMD} database:remove / --project "$GCP_PROJECT" --force
log "Adding data from musicBlog.json"
docker run -p 9005:9005 -v $PWD/../../connect/connect-gcp-firebase-source/keyfile.json:/tmp/keyfile.json:z -e GOOGLE_APPLICATION_CREDENTIALS="/tmp/keyfile.json" -v $PWD/../../connect/connect-gcp-firebase-source/musicBlog.json:/tmp/musicBlog.json:z -e PROJECT=$GCP_PROJECT ${FIREBASE_DOCKER_ARGS} -i ${FIREBASE_IMAGE} ${FIREBASE_CMD} database:set / /tmp/musicBlog.json --project "$GCP_PROJECT" --force
log "Verifying data is in Firebase"
docker run -p 9005:9005 -v $PWD/../../connect/connect-gcp-firebase-source/keyfile.json:/tmp/keyfile.json:z -e GOOGLE_APPLICATION_CREDENTIALS="/tmp/keyfile.json" -e PROJECT=$GCP_PROJECT ${FIREBASE_DOCKER_ARGS} -i ${FIREBASE_IMAGE} ${FIREBASE_CMD} database:get / --project "$GCP_PROJECT" | jq .

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"


log "Creating GCP Firebase Source connector"
playground connector create-or-update --connector firebase-source  << EOF
{
    "connector.class" : "io.confluent.connect.firebase.FirebaseSourceConnector",
    "tasks.max" : "1",
    "gcp.firebase.credentials.path": "/tmp/keyfile.json",
    "gcp.firebase.database.reference": "${GCP_FIREBASE_DATABASE_REFERENCE}",
    "gcp.firebase.snapshot":"true",
    "confluent.topic.bootstrap.servers": "broker:9092",
    "confluent.topic.replication.factor": "1",
    "errors.tolerance": "all",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true"
}
EOF

sleep 10

log "Verify messages are in topic artists"
playground topic consume --topic artists --min-expected-messages 3 --timeout 60

log "Verify messages are in topic songs"
playground topic consume --topic songs --min-expected-messages 3 --timeout 60
