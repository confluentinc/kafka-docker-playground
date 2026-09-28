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

if [ ! -f ${PWD}/redshift-jdbc42-2.1.0.17/redshift-jdbc42-2.1.0.17.jar ]
then
     mkdir -p redshift-jdbc42-2.1.0.17
     cd redshift-jdbc42-2.1.0.17
     wget -q https://s3.amazonaws.com/redshift-downloads/drivers/jdbc/2.1.0.17/redshift-jdbc42-2.1.0.17.zip
     unzip redshift-jdbc42-2.1.0.17.zip
     cd -
fi

handle_aws_credentials

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

CLUSTER_NAME=pg${USER}jdbcredshift${TAG}
CLUSTER_NAME=${CLUSTER_NAME//[-._]/}

function delete_redshift_security_group_with_retry {
  local CLUSTER_TO_DELETE=$1
  aws redshift wait cluster-deleted --cluster-identifier "$CLUSTER_TO_DELETE" 2>/dev/null
  log "Delete security group sg$CLUSTER_TO_DELETE, if required"
  local SG_DELETE_RETRIES=${SG_DELETE_RETRIES:-5}
  local sg_deleted=false
  for sg_attempt in $(seq 1 "$SG_DELETE_RETRIES"); do
      sleep 120
      if aws ec2 delete-security-group --group-name sg$CLUSTER_TO_DELETE
      then
          sg_deleted=true
          break
      fi
  done
  if [ "$sg_deleted" != true ]
  then
      logwarn "Failed to delete security group sg$CLUSTER_TO_DELETE after cluster $CLUSTER_TO_DELETE was deleted - it will not be retried"
  fi
}

# CLUSTER_NAME is unique per run, so a cluster from a killed job (SIGKILL, timeout,
# agent preemption) is never reused/reclaimed by a future run's exact-name delete.
# Reap this script's own clusters by age instead of by name so a killed job still gets cleaned
# up eventually, by whichever run notices it next.
function reap_redshift_cluster {
  local CLUSTER_TO_DELETE=$1
  # Unlike the old pre-create delete logic, this run's own cluster creation never depends
  # on this function to succeed. It is deleting some other run's leftover. So one attempt is enough: if
  # it fails (e.g. transient InvalidClusterState), the reaper picks it up again next
  # run, now even older instead of retrying/sleeping in this run for no benefit to it.
  local error
  error=$(aws redshift delete-cluster --cluster-identifier $CLUSTER_TO_DELETE --skip-final-cluster-snapshot 2>&1)
  if [ $? -eq 0 ]
  then
      log "Cluster $CLUSTER_TO_DELETE deleted successfully"
      # Once the cluster is gone it never reappears in a future describe-clusters scan,
      # so this is the only chance the reaper gets to clean up its security group.
      delete_redshift_security_group_with_retry "$CLUSTER_TO_DELETE"
      return 0
  else
      logwarn "Failed to reap cluster $CLUSTER_TO_DELETE: $error (will retry on a future run)"
      return 1
  fi
}

REDSHIFT_REAP_MAX_AGE_HOURS=${REDSHIFT_REAP_MAX_AGE_HOURS:-6}
REAP_PREFIX="pg${USER}jdbcredshift"
log "Reap AWS Redshift clusters matching ${REAP_PREFIX}* older than ${REDSHIFT_REAP_MAX_AGE_HOURS}h, if any"
set +e
NOW_EPOCH=$(date -u +%s)
STALE_CLUSTERS=$(aws redshift describe-clusters --query "Clusters[?starts_with(ClusterIdentifier, '${REAP_PREFIX}')].[ClusterIdentifier,ClusterCreateTime]" --output text)
if [ -n "$STALE_CLUSTERS" ]
then
    while IFS=$'\t' read -r STALE_NAME STALE_CREATE_TIME
    do
        [ -z "$STALE_NAME" ] && continue
        if [[ "$OSTYPE" == "darwin"* ]]
        then
            STALE_CREATE_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${STALE_CREATE_TIME%%.*}" +%s 2>/dev/null)
        else
            STALE_CREATE_EPOCH=$(date -u -d "$STALE_CREATE_TIME" +%s 2>/dev/null)
        fi
        [ -z "$STALE_CREATE_EPOCH" ] && continue
        AGE_HOURS=$(( (NOW_EPOCH - STALE_CREATE_EPOCH) / 3600 ))
        if [ "$AGE_HOURS" -ge "$REDSHIFT_REAP_MAX_AGE_HOURS" ]
        then
            logwarn "Reaping orphaned Redshift cluster $STALE_NAME (age ${AGE_HOURS}h)"
            reap_redshift_cluster "$STALE_NAME"
        fi
    done <<< "$STALE_CLUSTERS"
fi
set -e

log "Create AWS Redshift cluster"
# https://docs.aws.amazon.com/redshift/latest/mgmt/getting-started-cli.html
aws redshift create-cluster --cluster-identifier $CLUSTER_NAME --master-username masteruser --master-user-password myPassword1 --node-type ra3.large --cluster-type single-node --publicly-accessible --tags Key=cflt_managed_by,Value=user Key=cflt_managed_id,Value="$USER"

function cleanup_cloud_resources {
  set +e
  log "Delete AWS Redshift cluster $CLUSTER_NAME"
  check_if_continue
  aws redshift delete-cluster --cluster-identifier $CLUSTER_NAME --skip-final-cluster-snapshot
  delete_redshift_security_group_with_retry "$CLUSTER_NAME"
}
trap cleanup_cloud_resources EXIT

# Verify AWS Redshift cluster has started within MAX_WAIT seconds
MAX_WAIT=480
CUR_WAIT=0
log "⌛ Waiting up to $MAX_WAIT seconds for AWS Redshift cluster $CLUSTER_NAME to start"
aws redshift describe-clusters --cluster-identifier $CLUSTER_NAME | jq .Clusters[0].ClusterStatus > /tmp/out.txt 2>&1
while [[ ! $(cat /tmp/out.txt) =~ "available" ]]; do
     sleep 10
     aws redshift describe-clusters --cluster-identifier $CLUSTER_NAME | jq .Clusters[0].ClusterStatus > /tmp/out.txt 2>&1
     CUR_WAIT=$(( CUR_WAIT+10 ))
     if [[ "$CUR_WAIT" -gt "$MAX_WAIT" ]]; then
          echo -e "\nERROR: The logs in ${CONTROL_CENTER_CONTAINER} container do not show 'available' after $MAX_WAIT seconds. Please troubleshoot with 'docker container ps' and 'playground container logs --open --container <container>'.\n"
          exit 1
     fi
done
log "AWS Redshift cluster $CLUSTER_NAME has started!"

log "Create a security group"
GROUP_ID=$(aws ec2 create-security-group --group-name sg$CLUSTER_NAME --description "playground aws redshift" | jq -r .GroupId)
log "Allow ingress traffic from 0.0.0.0/0 on port 5439"
aws ec2 authorize-security-group-ingress --group-id $GROUP_ID --protocol tcp --port 5439 --cidr "0.0.0.0/0"
log "Modify AWS Redshift cluster to use the security group $GROUP_ID"
aws redshift modify-cluster --cluster-identifier $CLUSTER_NAME --vpc-security-group-ids $GROUP_ID

# getting cluster URL
CLUSTER=$(aws redshift describe-clusters --cluster-identifier $CLUSTER_NAME | jq -r .Clusters[0].Endpoint.Address)

set +e
docker run -i -e CLUSTER="$CLUSTER" -v "${DIR}/customers.sql":/tmp/customers.sql debezium/postgres:15-alpine psql -h "$CLUSTER" -U "masteruser" -d "dev" -p "5439" << EOF
myPassword1
DROP TABLE CUSTOMERS;
EOF
set -e

log "Create database in Redshift"
docker run -i -e CLUSTER="$CLUSTER" -v "${DIR}/customers.sql":/tmp/customers.sql debezium/postgres:15-alpine psql -h "$CLUSTER" -U "masteruser" -d "dev" -p "5439" -f "/tmp/customers.sql" << EOF
myPassword1
EOF

log "Verify data is in Redshift"
docker run -i -e CLUSTER="$CLUSTER" -v "${DIR}/customers.sql":/tmp/customers.sql debezium/postgres:15-alpine psql -h "$CLUSTER" -U "masteruser" -d "dev" -p "5439" << EOF
myPassword1
SELECT * from CUSTOMERS;
EOF

log "Creating JDBC AWS Redshift source connector"
playground connector create-or-update --connector redshift-jdbc-source  << EOF
{
     "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
     "tasks.max": "1",
     "connection.url": "jdbc:redshift://$CLUSTER:5439/dev?user=masteruser&password=myPassword1",
     "table.whitelist": "customers",
     "mode": "timestamp+incrementing",
     "timestamp.column.name": "update_ts",
     "incrementing.column.name": "id",
     "topic.prefix": "redshift-",
     "validate.non.null":"false",
     "errors.log.enable": "true",
     "errors.log.include.messages": "true"
}
EOF

sleep 30

log "Verifying topic redshift-customers"
playground topic consume --topic redshift-customers --min-expected-messages 5 --timeout 60
