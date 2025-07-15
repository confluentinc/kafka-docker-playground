#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if ! version_gt $TAG_BASE "5.3.99"; then
    logwarn "Audit logs is only available from Confluent Platform 5.4.0"
    exit 111
fi

JAAS_CONFIG_FILE="/tmp/jaas_config.file"
if version_gt $TAG_BASE "7.9.9"; then
  export JAAS_CONFIG_FILE="/tmp/jaas_config_8_plus.file"
fi

playground start-environment --environment rbac-sasl-plain --docker-compose-override-file "${PWD}/docker-compose.rbac-sasl-plain.yml"

log "Creating role binding for ACL topics"
docker exec -i tools bash -c "/create-role-bindings-acl.sh"

log "Creating initial ACLs"
docker exec -i schema-registry bash -c "/tmp/create-acls.sh"
