#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if [ ! -z "$TAG_BASE" ] && version_gt $TAG_BASE "7.9.99" && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "10.7.99"
then
     logwarn "minimal supported connector version is 10.8.0 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

# https://docs.docker.com/compose/profiles/
profile_control_center_command=""
if [ -z "$ENABLE_CONTROL_CENTER" ]
then
  log "🛑 control-center is disabled"
else
  log "💠 control-center is enabled"
  log "Use http://localhost:9021 to login"
  profile_control_center_command="--profile control-center"
fi

profile_ksqldb_command=""
if [ -z "$ENABLE_KSQLDB" ]
then
  log "🛑 ksqldb is disabled"
else
  log "🚀 ksqldb is enabled"
  log "🔧 You can use ksqlDB with CLI using:"
  log "docker exec -i ksqldb-cli ksql http://ksqldb-server:8088"
  profile_ksqldb_command="--profile ksqldb"
fi

set_profiles
docker compose -f ../../environment/plaintext/docker-compose.yml ${KRAFT_DOCKER_COMPOSE_FILE_OVERRIDE} -f "${PWD}/docker-compose.plaintext.yml" ${profile_control_center_command} ${profile_ksqldb_command} ${profile_zookeeper_command}  ${profile_grafana_command} ${profile_kcat_command} down -v --remove-orphans
log "Starting up ibmdb2 container to get db2jcc4.jar"
docker compose -f ../../environment/plaintext/docker-compose.yml ${KRAFT_DOCKER_COMPOSE_FILE_OVERRIDE} -f "${PWD}/docker-compose.plaintext.yml" ${profile_control_center_command} ${profile_ksqldb_command} ${profile_zookeeper_command}  ${profile_grafana_command} ${profile_kcat_command} up -d ibmdb2

cd ../../connect/connect-jdbc-ibmdb2-sink
rm -f db2jcc4.jar
log "Getting db2jcc4.jar"
docker cp ibmdb2:/opt/ibm/db2/V11.5/java/db2jcc4.jar db2jcc4.jar
cd -

playground container logs --container ibmdb2 --wait-for-log "Setup has completed" --max-wait 600
log "ibmdb2 DB has started!"

set_profiles
docker compose -f ../../environment/plaintext/docker-compose.yml ${KRAFT_DOCKER_COMPOSE_FILE_OVERRIDE} -f "${PWD}/docker-compose.plaintext.yml" ${profile_control_center_command} ${profile_ksqldb_command} ${profile_zookeeper_command}  ${profile_grafana_command} ${profile_kcat_command} up -d --quiet-pull
command="source ${DIR}/../../scripts/utils.sh && docker compose -f ${DIR}/../../environment/plaintext/docker-compose.yml ${KRAFT_DOCKER_COMPOSE_FILE_OVERRIDE} -f "${PWD}/docker-compose.plaintext.yml" ${profile_control_center_command} ${profile_ksqldb_command} ${profile_zookeeper_command}  ${profile_grafana_command} ${profile_kcat_command} up -d"
playground state set run.docker_command "$command"
playground state set run.environment "plaintext"

wait_container_ready

# Keep it for utils.sh
# PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
#playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

log "Sending messages to topic ORDERS"
playground topic produce -t ORDERS --nb-messages 1 << 'EOF'
{
  "type": "record",
  "name": "myrecord",
  "fields": [
    {
      "name": "ID",
      "type": "int"
    },
    {
      "name": "PRODUCT",
      "type": "string"
    },
    {
      "name": "QUANTITY",
      "type": "int"
    },
    {
      "name": "PRICE",
      "type": "float"
    }
  ]
}
EOF

playground topic produce -t ORDERS --nb-messages 1 --forced-value '{"ID":2,"PRODUCT":"foo","QUANTITY":2,"PRICE":0.86583304}' << 'EOF'
{
  "type": "record",
  "name": "myrecord",
  "fields": [
    {
      "name": "ID",
      "type": "int"
    },
    {
      "name": "PRODUCT",
      "type": "string"
    },
    {
      "name": "QUANTITY",
      "type": "int"
    },
    {
      "name": "PRICE",
      "type": "float"
    }
  ]
}
EOF

log "Creating JDBC IBM DB2 sink connector"
playground connector create-or-update --connector ibmdb2-sink  << EOF
{
  "connector.class": "io.confluent.connect.jdbc.JdbcSinkConnector",
  "tasks.max": "1",
  "connection.url":"jdbc:db2://ibmdb2:25010/sample",
  "connection.user":"db2inst1",
  "connection.password":"passw0rd",
  "topics": "ORDERS",
  "errors.log.enable": "true",
  "errors.log.include.messages": "true",
  "auto.create": "true"
}
EOF


sleep 15

log "Check data is in IBM DB2"
docker exec -i ibmdb2 bash << EOF > /tmp/result.log
su - db2inst1
db2 connect to sample user db2inst1 using passw0rd
db2 select ID,PRODUCT,QUANTITY,PRICE from ORDERS
EOF
cat /tmp/result.log
grep "foo" /tmp/result.log

