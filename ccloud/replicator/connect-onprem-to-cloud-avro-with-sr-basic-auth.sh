#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if version_gt $TAG_BASE "7.9.9"; then
    logerror "This can only be run with image or version lower than 8.0.0"
    exit 111
fi

#############
playground start-environment --environment ccloud --docker-compose-override-file "${PWD}/docker-compose-connect-onprem-to-cloud-with-sr-basic-auth.yml"


#############

log "Creating topic in Confluent Cloud (auto.create.topics.enable=false)"
set +e
playground topic delete --topic products-avro
sleep 3
playground topic create --topic products-avro
set -e

log "Sending messages to topic products-avro on source OnPREM cluster"
docker exec -i connect kafka-avro-console-producer --bootstrap-server broker:9092 --property schema.registry.url=http://schema-registry:8081 --property basic.auth.credentials.source=USER_INFO --property schema.registry.basic.auth.user.info='admin:admin' --topic products-avro --property value.schema='{"type":"record","name":"myrecord","fields":[{"name":"name","type":"string"},{"name":"price", "type": "float"}, {"name":"quantity", "type": "int"}]}' --property key.schema='{"type":"string"}' --property parse.key=true --property key.separator=":" << EOF
"122346":{"name": "scissors", "price": 2.75, "quantity": 3}
"122347":{"name": "tape", "price": 0.99, "quantity": 10}
"122348":{"name": "notebooks", "price": 1.99, "quantity": 5}
EOF

playground connector create-or-update --connector replicate-onprem-to-cloud  << EOF
{
  "connector.class":"io.confluent.connect.replicator.ReplicatorSourceConnector",
  "src.consumer.group.id": "replicate-onprem-to-cloud",
  "src.key.converter": "io.confluent.connect.avro.AvroConverter",
  "src.key.converter.schema.registry.url": "http://schema-registry:8081",
  "src.key.converter.basic.auth.user.info": "admin:admin",
  "src.key.converter.basic.auth.credentials.source": "USER_INFO",
  "src.value.converter": "io.confluent.connect.avro.AvroConverter",
  "src.value.converter.schema.registry.url": "http://schema-registry:8081",
  "src.value.converter.basic.auth.user.info": "admin:admin",
  "src.value.converter.basic.auth.credentials.source": "USER_INFO",
  "src.kafka.bootstrap.servers": "broker:9092",

  "dest.kafka.ssl.endpoint.identification.algorithm":"https",
  "dest.kafka.bootstrap.servers": "\${file:/datacloud:bootstrap.servers}",
  "dest.kafka.security.protocol" : "SASL_SSL",
  "dest.kafka.sasl.jaas.config": "org.apache.kafka.common.security.plain.PlainLoginModule required username=\"\${file:/datacloud:sasl.username}\" password=\"\${file:/datacloud:sasl.password}\";",
  "dest.kafka.sasl.mechanism":"PLAIN",
  "dest.kafka.request.timeout.ms":"20000",
  "dest.kafka.retry.backoff.ms":"500",

  "key.converter": "io.confluent.connect.avro.AvroConverter",
  "key.converter.schema.registry.url": "$SCHEMA_REGISTRY_URL",
  "key.converter.basic.auth.user.info": "\${file:/datacloud:schema.registry.basic.auth.user.info}",
  "key.converter.basic.auth.credentials.source": "USER_INFO",

  "value.converter": "io.confluent.connect.avro.AvroConverter",
  "value.converter.schema.registry.url": "$SCHEMA_REGISTRY_URL",
  "value.converter.basic.auth.user.info": "\${file:/datacloud:schema.registry.basic.auth.user.info}",
  "value.converter.basic.auth.credentials.source": "USER_INFO",

  "confluent.topic.ssl.endpoint.identification.algorithm" : "https",
  "confluent.topic.sasl.mechanism" : "PLAIN",
  "confluent.topic.bootstrap.servers": "\${file:/datacloud:bootstrap.servers}",
  "confluent.topic.sasl.jaas.config" : "org.apache.kafka.common.security.plain.PlainLoginModule required username=\"\${file:/datacloud:sasl.username}\" password=\"\${file:/datacloud:sasl.password}\";",
  "confluent.topic.security.protocol" : "SASL_SSL",
  "confluent.topic.replication.factor": "3",
  "provenance.header.enable": true,
  "topic.whitelist": "products-avro",
  "topic.config.sync": false,
  "topic.auto.create": false
}
EOF

# In order to remove avro converter metadata added in schema, we can set:
# "value.converter.connect.meta.data": false

log "Verify we have received the data in products-avro topic"
playground topic consume --topic products-avro --min-expected-messages 3 --timeout 60
