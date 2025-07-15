#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if [ ! -z $ENABLE_KRAFT ]
then
  # KRAFT mode
  playground start-environment --environment sasl-plain --docker-compose-override-file "${PWD}/docker-compose.sasl-plain-kraft.yml"
else
  # Zookeeper mode
  playground start-environment --environment sasl-plain --docker-compose-override-file "${PWD}/docker-compose.sasl-plain.yml"
fi

docker exec sftp-server bash -c "
mkdir -p /chroot/home/foo/upload/input
mkdir -p /chroot/home/foo/upload/error
mkdir -p /chroot/home/foo/upload/finished

chown -R foo /chroot/home/foo/upload
"

echo $'id,first_name,last_name,email,gender,ip_address,last_login,account_balance,country,favorite_color\n1,Salmon,Baitman,sbaitman0@feedburner.com,Male,120.181.75.98,2015-03-01T06:01:15Z,17462.66,IT,#f09bc0\n2,Debby,Brea,dbrea1@icio.us,Female,153.239.187.49,2018-10-21T12:27:12Z,14693.49,CZ,#73893a' > csv-sftp-source.csv

docker cp csv-sftp-source.csv sftp-server:/chroot/home/foo/upload/input/
rm -f csv-sftp-source.csv

# Principal = User:sftp is Denied Operation = Describe from host = 192.168.208.6 on resource = Topic:LITERAL:sftp-testing-topic (kafka.authorizer.logger)

docker exec broker kafka-acls --bootstrap-server broker:9092 --add --allow-principal User:sftp --producer --topic sftp-testing-topic --command-config /tmp/client.properties

# Adding ACLs for resource `Topic:LITERAL:sftp-testing-topic`:
#         User:sftp has Allow permission for operations: Create from hosts: *
#         User:sftp has Allow permission for operations: Describe from hosts: *
#         User:sftp has Allow permission for operations: Write from hosts: *

log "Creating CSV SFTP Source connector"
playground connector create-or-update --connector sftp-source  << EOF
{
        "topics": "test_sftp_sink",
        "tasks.max": "1",
        "connector.class": "io.confluent.connect.sftp.SftpCsvSourceConnector",
        "cleanup.policy":"NONE",
        "behavior.on.error":"IGNORE",
        "input.path": "/home/foo/upload/input",
        "error.path": "/home/foo/upload/error",
        "finished.path": "/home/foo/upload/finished",
        "input.file.pattern": "csv-sftp-source.csv",
        "sftp.username":"foo",
        "sftp.password":"pass",
        "sftp.host":"sftp-server",
        "sftp.port":"22",
        "kafka.topic": "sftp-testing-topic",
        "csv.first.row.as.header": "true",
        "schema.generation.enabled": "true",
        "producer.override.sasl.mechanism": "PLAIN",
        "producer.override.security.protocol": "SASL_PLAINTEXT",
        "producer.override.sasl.jaas.config" : "org.apache.kafka.common.security.plain.PlainLoginModule required username=\"sftp\" password=\"sftp-secret\";"
}
EOF

sleep 5

log "Verifying topic sftp-testing-topic"
timeout 60 docker exec connect kafka-avro-console-consumer -bootstrap-server broker:9092 --property schema.registry.url=http://schema-registry:8081 --topic sftp-testing-topic --consumer.config /tmp/client.properties --from-beginning --max-messages 2