#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

# make sure ksqlDB is not disabled
export ENABLE_KSQLDB=true

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}"

# has to remove the price field otherwise it fails because ksqlDB schema inference is not able to handle float32
# https://github.com/confluentinc/ksql/issues/9740
docker exec -i connect curl -s -H "Content-Type: application/vnd.schemaregistry.v1+json" -X POST http://schema-registry:8081/subjects/orders-value/versions --data '{"schema":"{\"type\":\"record\",\"name\":\"myrecord\",\"fields\":[{\"name\":\"id\",\"type\":\"int\"},{\"name\":\"product\",\"type\":\"string\"},{\"name\":\"quantity\",\"type\":\"int\"}]}"}'

log "Checking the schema existence in the schema registry"
docker exec -i connect curl -s GET http://schema-registry:8081/subjects/orders-value/versions/1

log "Sending messages to topic orders"
docker exec -i connect kafka-avro-console-producer --bootstrap-server broker:9092 --property schema.registry.url=http://schema-registry:8081 --topic orders --property value.schema.id=1 << EOF
{"id": 111, "product": "foo1", "quantity": 101}
{"id": 222, "product": "foo2", "quantity": 102}
EOF

# Wait for the stream to be initialized
sleep 5

log "Create the ksqlDB streams"
timeout 120 docker exec -i ksqldb-cli ksql http://ksqldb-server:8088 << EOF

SET 'auto.offset.reset' = 'earliest';

CREATE STREAM orders
  WITH (
    KAFKA_TOPIC='orders',
    VALUE_FORMAT='AVRO'
  );

SELECT * FROM orders;

CREATE STREAM orders_new
WITH (
  KAFKA_TOPIC='orders_new',
  VALUE_FORMAT='AVRO') AS
SELECT
  *
FROM orders;

EOF

log "Updating the schema"
docker exec -i connect curl -s -H "Content-Type: application/vnd.schemaregistry.v1+json" -X POST http://schema-registry:8081/subjects/orders-value/versions --data '{"schema":"{\"type\":\"record\",\"name\":\"myrecord\",\"fields\":[{\"name\":\"id\",\"type\":\"int\"},{\"name\":\"product\",\"type\":\"string\"},{\"name\":\"quantity\",\"type\":\"int\"},{\"name\":\"category\",\"type\":\"string\",\"default\":\"default_category\"}]}"}'

log "Checking the schema existence of the new version in the schema registry"
docker exec -i connect curl -s GET http://schema-registry:8081/subjects/orders-value/versions/2

log "Sending messages to topic orders using the new schema "
docker exec -i connect kafka-avro-console-producer --bootstrap-server broker:9092 --property schema.registry.url=http://schema-registry:8081 --topic orders --property value.schema.id=3 << EOF
{"id": 333, "product": "foo3", "quantity": 103, "category": "sample"}
{"id": 444, "product": "foo4", "quantity": 104, "category": "sample"}
EOF

# Wait for the stream to be initialized
sleep 5

log "Reading from ksqlDB stream"
timeout 120 docker exec -i ksqldb-cli ksql http://ksqldb-server:8088 << EOF

SET 'auto.offset.reset' = 'earliest';

SELECT * FROM orders;
SELECT * FROM orders_new;
EOF

log "As for changes to your schema, it will be necessary to create a new ksql stream to handle such changes."
timeout 120 docker exec -i ksqldb-cli ksql http://ksqldb-server:8088 << EOF
SET 'auto.offset.reset' = 'earliest';

TERMINATE CSAS_ORDERS_NEW_1;
DROP STREAM orders_new;

CREATE OR REPLACE STREAM orders
  WITH (
    KAFKA_TOPIC='orders',
    VALUE_FORMAT='AVRO'
  );

CREATE OR REPLACE STREAM orders_new
WITH (
  KAFKA_TOPIC='orders_new',
  VALUE_FORMAT='AVRO') AS
SELECT
  *
FROM orders;

SELECT * FROM orders;
SELECT * FROM orders_new;

EOF
