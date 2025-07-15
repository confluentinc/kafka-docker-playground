#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if version_gt $TAG_BASE "7.9.99"
then
     logwarn "preview connectors are no longer supported with CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

cd ../../connect/connect-ftps-source/security
playground tools certs-create --output-folder "$PWD" --container ftps-server
docker run --quiet --rm -v $PWD:/tmp alpine/openssl req -x509 -nodes -days 365 -newkey rsa:1024 -keyout /tmp/vsftpd.pem -out /tmp/vsftpd.pem  -config /tmp/cert_config -reqexts 'my server exts'
cd -

if [[ "$(uname)" != "Darwin" ]]
then
     # Linux
     sudo chown root ${DIR}/config/vsftpd.conf
     sudo chown root ${DIR}/security/vsftpd.pem
fi

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

docker exec ftps-server bash -c "
mkdir -p /home/vsftpd/bob/input
mkdir -p /home/vsftpd/bob/error
mkdir -p /home/vsftpd/bob/finished

chown -R ftp /home/vsftpd/bob
"

echo $'{"id":1,"first_name":"Roscoe","last_name":"Brentnall","email":"rbrentnall0@mediafire.com","gender":"Male","ip_address":"202.84.142.254","last_login":"2018-02-12T06:26:23Z","account_balance":1450.68,"country":"CZ","favorite_color":"#4eaefa"}\n{"id":2,"first_name":"Gregoire","last_name":"Fentem","email":"gfentem1@nsw.gov.au","gender":"Male","ip_address":"221.159.106.63","last_login":"2015-03-27T00:29:56Z","account_balance":1392.37,"country":"ID","favorite_color":"#e8f686"}' > json-ftps-source.json

docker cp json-ftps-source.json ftps-server:/home/vsftpd/bob/input/
rm -f json-ftps-source.json

log "Creating JSON file with schema FTPS Source connector"
playground connector create-or-update --connector ftps-source-json  << EOF
{
     "tasks.max": "1",
     "connector.class": "io.confluent.connect.ftps.FtpsSourceConnector",
     "ftps.behavior.on.error":"LOG",
     "ftps.input.path": "/input",
     "ftps.error.path": "/error",
     "ftps.finished.path": "/finished",
     "ftps.input.file.pattern": "json-ftps-source.json",
     "ftps.username":"bob",
     "ftps.password":"test",
     "ftps.host":"ftps-server",
     "ftps.port":"220",
     "ftps.security.mode": "EXPLICIT",
     "confluent.license": "",
     "confluent.topic.bootstrap.servers": "broker:9092",
     "confluent.topic.replication.factor": "1",
     "ftps.ssl.truststore.location": "/etc/kafka/secrets/kafka.ftps-server.truststore.jks",
     "ftps.ssl.truststore.password": "confluent",
     "ftps.ssl.keystore.location": "/etc/kafka/secrets/kafka.ftps-server.keystore.jks",
     "ftps.ssl.key.password": "confluent",
     "ftps.ssl.keystore.password": "confluent",
     "kafka.topic": "ftps-testing-topic",
     "schema.generation.enabled": "false",
     "key.converter": "io.confluent.connect.avro.AvroConverter",
     "key.converter.schema.registry.url": "http://schema-registry:8081",
     "value.converter": "io.confluent.connect.avro.AvroConverter",
     "value.converter.schema.registry.url": "http://schema-registry:8081",
     "key.schema": "{\"name\" : \"com.example.users.UserKey\",\"type\" : \"STRUCT\",\"isOptional\" : false,\"fieldSchemas\" : {\"id\" : {\"type\" : \"INT64\",\"isOptional\" : false}}}",
     "value.schema": "{\"name\" : \"com.example.users.User\",\"type\" : \"STRUCT\",\"isOptional\" : false,\"fieldSchemas\" : {\"id\" : {\"type\" : \"INT64\",\"isOptional\" : false},\"first_name\" : {\"type\" : \"STRING\",\"isOptional\" : true},\"last_name\" : {\"type\" : \"STRING\",\"isOptional\" : true},\"email\" : {\"type\" : \"STRING\",\"isOptional\" : true},\"gender\" : {\"type\" : \"STRING\",\"isOptional\" : true},\"ip_address\" : {\"type\" : \"STRING\",\"isOptional\" : true},\"last_login\" : {\"type\" : \"STRING\",\"isOptional\" : true},\"account_balance\" : {\"name\" : \"org.apache.kafka.connect.data.Decimal\",\"type\" : \"BYTES\",\"version\" : 1,\"parameters\" : {\"scale\" : \"2\"},\"isOptional\" : true},\"country\" : {\"type\" : \"STRING\",\"isOptional\" : true},\"favorite_color\" : {\"type\" : \"STRING\",\"isOptional\" : true}}}",
     "errors.tolerance": "all",
     "errors.log.enable": "true",
     "errors.log.include.messages": "true"
}
EOF

sleep 5

log "Verifying topic ftps-testing-topic"
playground topic consume --topic ftps-testing-topic --min-expected-messages 2 --timeout 60