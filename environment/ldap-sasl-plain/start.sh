#!/bin/bash

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if ! version_gt $TAG_BASE "5.3.99"; then
    logwarn "Kafka Client Authentication with LDAP was added in CP 5.4"
    exit 111
fi

if [[ $CP_CONNECT_IMAGE == *"cp-kafka-"* ]] || [[ $CP_KAFKA_IMAGE == *"cp-kafka" ]]
then
  logwarn "Kafka Client Authentication with LDAP is not available with community image"
  exit 111
fi

verify_docker_and_memory

check_docker_compose_version
check_bash_version
check_and_update_playground_version
nb_connect_services=0
ENABLE_DOCKER_COMPOSE_FILE_OVERRIDE=""
DOCKER_COMPOSE_FILE_OVERRIDE=$1
if [ -f "${DOCKER_COMPOSE_FILE_OVERRIDE}" ]
then
  ENABLE_DOCKER_COMPOSE_FILE_OVERRIDE="-f ${DOCKER_COMPOSE_FILE_OVERRIDE}"
  set +e
  nb_connect_services=$(grep -Ec "connect[0-9]+:" ${DOCKER_COMPOSE_FILE_OVERRIDE})
  set -e
  check_arm64_support "${DIR}" "${DOCKER_COMPOSE_FILE_OVERRIDE}"
fi
set_profiles

docker compose -f ../../environment/plaintext/docker-compose.yml ${KRAFT_DOCKER_COMPOSE_FILE_OVERRIDE} -f ../../environment/sasl-plain/docker-compose.yml -f ../../environment/ldap-sasl-plain/docker-compose.yml ${ENABLE_DOCKER_COMPOSE_FILE_OVERRIDE}  ${profile_control_center_command} ${profile_ksqldb_command} ${profile_zookeeper_command}  ${profile_grafana_command} ${profile_conduktor_command} ${profile_kafka_nodes_command} ${profile_connect_nodes_command} build
docker compose -f ../../environment/plaintext/docker-compose.yml ${KRAFT_DOCKER_COMPOSE_FILE_OVERRIDE} -f ../../environment/sasl-plain/docker-compose.yml -f ../../environment/ldap-sasl-plain/docker-compose.yml ${ENABLE_DOCKER_COMPOSE_FILE_OVERRIDE}  ${profile_control_center_command} ${profile_ksqldb_command} ${profile_zookeeper_command}  ${profile_grafana_command} ${profile_conduktor_command} ${profile_kafka_nodes_command} ${profile_connect_nodes_command} down -v --remove-orphans
docker compose -f ../../environment/plaintext/docker-compose.yml ${KRAFT_DOCKER_COMPOSE_FILE_OVERRIDE} -f ../../environment/sasl-plain/docker-compose.yml -f ../../environment/ldap-sasl-plain/docker-compose.yml ${ENABLE_DOCKER_COMPOSE_FILE_OVERRIDE} ${profile_control_center_command} ${profile_ksqldb_command} ${profile_zookeeper_command}  ${profile_grafana_command} ${profile_kcat_command} ${profile_kafka_nodes_command} ${profile_connect_nodes_command} up -d --quiet-pull
log "📝 To see the actual properties file, use cli command 'playground container get-properties -c <container>'"
command="source ${DIR}/../../scripts/utils.sh && docker compose -f ${DIR}/../../environment/plaintext/docker-compose.yml ${KRAFT_DOCKER_COMPOSE_FILE_OVERRIDE} -f ${DIR}/../../environment/sasl-plain/docker-compose.yml -f ../../environment/ldap-sasl-plain/docker-compose.yml ${ENABLE_DOCKER_COMPOSE_FILE_OVERRIDE} ${profile_control_center_command} ${profile_ksqldb_command} ${profile_zookeeper_command}  ${profile_grafana_command} ${profile_kcat_command}  ${profile_kafka_nodes_command} ${profile_connect_nodes_command} up -d --quiet-pull"
playground state set run.docker_command "$command"
playground state set run.environment "ldap-sasl-plain"
log "✨ If you modify a docker-compose file and want to re-create the container(s), run cli command 'playground container recreate'"



wait_container_ready

display_jmx_info