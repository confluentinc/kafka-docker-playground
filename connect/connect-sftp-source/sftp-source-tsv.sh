#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if [ ! -z "$TAG_BASE" ] && version_gt $TAG_BASE "7.9.99" && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "3.1.99"
then
     logwarn "minimal supported connector version is 3.2.0 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

docker exec sftp-server bash -c "
mkdir -p /chroot/home/foo/upload/input
mkdir -p /chroot/home/foo/upload/error
mkdir -p /chroot/home/foo/upload/finished

chown -R foo /chroot/home/foo/upload
"

echo $'id\tfirst_name\tlast_name\temail\tgender\tip_address\tlast_login\taccount_balance\tcountry\tfavorite_color\n1\tPadraig\tOxshott\tpoxshott0@dion.ne.jp\tMale\t47.243.121.95\t2016-06-24T22:43:42Z\t15274.22\tJP\t#06708f\n2\tEdi\tOrrah\teorrah1@cafepress.com\tFemale\t158.229.234.101\t2017-03-01T17:52:47Z\t12947.6\tCN\t#5f2aa2' > tsv-sftp-source.tsv

docker cp tsv-sftp-source.tsv sftp-server:/chroot/home/foo/upload/input/
rm -f tsv-sftp-source.tsv

log "Creating TSV SFTP Source connector"
playground connector create-or-update --connector sftp-source-tsv  << EOF
{
     "tasks.max": "1",
     "connector.class": "io.confluent.connect.sftp.SftpCsvSourceConnector",
     "cleanup.policy":"NONE",
     "behavior.on.error":"IGNORE",
     "input.path": "/home/foo/upload/input",
     "error.path": "/home/foo/upload/error",
     "finished.path": "/home/foo/upload/finished",
     "input.file.pattern": "tsv-sftp-source.tsv",
     "sftp.username":"foo",
     "sftp.password":"pass",
     "sftp.host":"sftp-server",
     "sftp.port":"22",
     "kafka.topic": "sftp-testing-topic",
     "csv.first.row.as.header": "true",
     "schema.generation.enabled": "true",
     "csv.separator.char": "9"
}
EOF

sleep 15

log "Verifying topic sftp-testing-topic"
playground topic consume --topic sftp-testing-topic --min-expected-messages 2 --timeout 60