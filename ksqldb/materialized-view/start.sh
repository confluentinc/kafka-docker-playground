#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if ! version_gt $TAG_BASE "5.4.99"; then
    logwarn "This example with connectors works since CP 5.5 only"
    exit 111
fi

# make sure ksqlDB is not disabled
export ENABLE_KSQLDB=true

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

log "Describing the calls table in DB 'mydb':"
docker exec mysql bash -c "mysql --user=root --password=password --database=mydb -e 'describe calls'"

log "Show content of calls table:"
docker exec mysql bash -c "mysql --user=root --password=password --database=mydb -e 'select * from calls'"


log "Create source connector"
timeout 120 docker exec -i ksqldb-cli ksql http://ksqldb-server:8088 << EOF

SET 'auto.offset.reset' = 'earliest';

CREATE SOURCE CONNECTOR calls_reader WITH (
    'connector.class' = 'io.debezium.connector.mysql.MySqlConnector',
    'database.hostname' = 'mysql',
    'database.port' = '3306',
    'database.user' = 'debezium',
    'database.password' = 'dbz',
    'database.allowPublicKeyRetrieval' = 'true',
    'database.server.id' = '223344',
    'table.whitelist' = 'mydb.calls',

    'database.names'  = 'mydb',
    '_comment' = 'old version before 2.x',
    'database.server.name' = 'dbserver1',
    'database.history.kafka.bootstrap.servers' = 'broker:9092',
    'database.history.kafka.topic' = 'call-center',
    '_comment 2' = 'new version since 2.x',
    'topic.prefix' = 'dbserver1',
    'schema.history.internal.kafka.bootstrap.servers' = 'broker:9092',
    'schema.history.internal.kafka.topic' = 'call-center',

    'include.schema.changes' = 'false'
);
EOF



sleep 5

log "Check topic"
timeout 120 docker exec -i ksqldb-cli ksql http://ksqldb-server:8088 << EOF

SET 'auto.offset.reset' = 'earliest';

SHOW TOPICS;
PRINT 'dbserver1.mydb.calls' FROM BEGINNING LIMIT 10;
DESCRIBE CONNECTOR calls_reader;
EOF

log "Create the ksqlDB calls stream"
timeout 120 docker exec -i ksqldb-cli ksql http://ksqldb-server:8088 << EOF

SET 'auto.offset.reset' = 'earliest';

CREATE STREAM calls WITH (
    kafka_topic = 'dbserver1.mydb.calls',
    value_format = 'avro'
);
EOF


log "Create the materialized views"
timeout 120 docker exec -i ksqldb-cli ksql http://ksqldb-server:8088 << EOF

SET 'auto.offset.reset' = 'earliest';

CREATE TABLE support_view AS
    SELECT after->name AS name,
           count_distinct(after->reason) AS distinct_reasons,
           latest_by_offset(after->reason) AS last_reason
    FROM calls
    GROUP BY after->name
    EMIT CHANGES;

CREATE TABLE lifetime_view AS
    SELECT after->name AS name,
           count(after->reason) AS total_calls,
           (sum(after->duration_seconds) / 60) as minutes_engaged
    FROM calls
    GROUP BY after->name
    EMIT CHANGES;
EOF

sleep 5

if ! version_gt $TAG_BASE "5.9.9"; then
    # with 5.5.x, we need to use ROWKEY
    log "Query the materialized views"
timeout 120 docker exec -i ksqldb-cli ksql http://ksqldb-server:8088 << EOF

SET 'auto.offset.reset' = 'earliest';

SELECT name, distinct_reasons, last_reason
FROM support_view
WHERE ROWKEY = 'derek';

SELECT name, total_calls, minutes_engaged
FROM lifetime_view
WHERE ROWKEY = 'michael';
EOF
else
    log "Query the materialized views"
timeout 120 docker exec -i ksqldb-cli ksql http://ksqldb-server:8088 << EOF

SET 'auto.offset.reset' = 'earliest';

SELECT name, distinct_reasons, last_reason
FROM support_view
WHERE name = 'derek';

SELECT name, total_calls, minutes_engaged
FROM lifetime_view
WHERE name = 'michael';
EOF
fi




# log "Adding an element to the table"
# docker exec mysql mysql --user=root --password=password --database=mydb -e "
# INSERT INTO calls (   \
#   id,   \
#   name, \
#   email,   \
#   last_modified \
# ) VALUES (  \
#   2,    \
#   'another',  \
#   'another@apache.org',   \
#   NOW() \
# ); "

# log "Show content of calls table:"
# docker exec mysql bash -c "mysql --user=root --password=password --database=mydb -e 'select * from calls'"

# log "Creating Debezium MySQL source connector"
# curl -X PUT \
#      -H "Content-Type: application/json" \
#      --data '{
#                "connector.class": "io.debezium.connector.mysql.MySqlConnector",
#                     "tasks.max": "1",
#                     "database.hostname": "mysql",
#                     "database.port": "3306",
#                     "database.user": "debezium",
#                     "database.password": "dbz",
#                     "database.server.id": "223344",
#                     "database.server.name": "dbserver1",
#                     "database.whitelist": "mydb",
#                     "database.history.kafka.bootstrap.servers": "broker:9092",
#                     "database.history.kafka.topic": "schema-changes.mydb",
#                     "transforms": "RemoveDots",
#                     "transforms.RemoveDots.type": "org.apache.kafka.connect.transforms.RegexRouter",
#                     "transforms.RemoveDots.regex": "(.*)\\\\.(.*)\\\\.(.*)",
#                     "transforms.RemoveDots.replacement": "\$1_\$2_\$3"
#           }' \
#      http://localhost:8083/connectors/debezium-mysql-source/config | jq .

# sleep 5

# log "Verifying topic dbserver1.mydb.calls"
playground topic consume --topic dbserver1.mydb.calls --min-expected-messages 2 --timeout 60


