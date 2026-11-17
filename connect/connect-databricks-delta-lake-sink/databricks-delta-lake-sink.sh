#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

# Databricks SQL warehouses auto stop after some inactivity (10 minutes minimum)
# usage: databricks_ensure_sql_warehouse_running <server hostname> <token> <http path>
function databricks_ensure_sql_warehouse_running () {
  local host="${1#https://}"
  host="${host%%/*}"
  local token="$2"
  local http_path="$3"

  if [ -z "$host" ] || [ -z "$token" ] || [ -z "$http_path" ]
  then
    logwarn "🧱 Databricks hostname, token or http path is not set, not checking if SQL warehouse is running"
    return 0
  fi

  if [[ "$http_path" != *"/warehouses/"* ]]
  then
    logwarn "🧱 Databricks http path $http_path is not a SQL warehouse, not checking if it is running"
    return 0
  fi

  local warehouse_id="${http_path##*/}"
  local url="https://${host}/api/2.0/sql/warehouses/${warehouse_id}"

  local max_wait=900
  local cur_wait=0
  local start_requested=0
  local state=""
  while true
  do
    local response
    response=$(curl -s -H "Authorization: Bearer ${token}" "$url")
    state=$(echo "$response" | jq -r '.state // empty' 2>/dev/null)
    if [ -z "$state" ]
    then
      logwarn "🧱 could not get Databricks SQL warehouse ${warehouse_id} state, not checking if it is running: $response"
      return 0
    fi
    log "🧱 Databricks SQL warehouse ${warehouse_id} state is ${state}"

    case "$state" in
      RUNNING)
        break
        ;;
      STOPPED)
        if [ $start_requested -eq 0 ]
        then
          log "🔌 Starting Databricks SQL warehouse ${warehouse_id}"
          local http_code
          http_code=$(curl -s -o /tmp/databricks_warehouse_start.txt -w '%{http_code}' -X POST -H "Authorization: Bearer ${token}" "${url}/start")
          if [ "$http_code" != "200" ]
          then
            # the connector would only fail minutes later with a JDBC "Communication link failure", fail now with the real reason
            # (e.g. denyReason INACTIVE: Databricks blocks all compute in the workspace)
            local message
            message=$(jq -r '[.message // empty] + [.details[]?.metadata.denyReason // empty | "(denyReason: " + . + ")"] | join(" ")' /tmp/databricks_warehouse_start.txt 2>/dev/null)
            logerror "❌ Databricks refused to start SQL warehouse ${warehouse_id} (http code $http_code): ${message:-$(cat /tmp/databricks_warehouse_start.txt)}"
            cat /tmp/databricks_warehouse_start.txt
            echo ""
            exit 1
          fi
          start_requested=1
        fi
        ;;
      DELETING|DELETED)
        logerror "❌ Databricks SQL warehouse ${warehouse_id} is ${state}"
        exit 1
        ;;
    esac

    if [[ "$cur_wait" -ge "$max_wait" ]]
    then
      logerror "❌ Databricks SQL warehouse ${warehouse_id} is still ${state} after $max_wait seconds"
      exit 1
    fi
    sleep 10
    cur_wait=$(( cur_wait+10 ))
  done
  log "✅ Databricks SQL warehouse ${warehouse_id} is running"
}

# Run one SQL statement on a Databricks all-purpose cluster (Command Execution API, as the SQL
# Statement Execution API only takes a SQL warehouse) and print its rows as a JSON array.
# Exits with the Databricks error message when it fails.
function databricks_cluster_sql_statement () {
  local host="$1"
  local token="$2"
  local cluster_id="$3"
  local statement="$4"
  local api="https://${host}/api/1.2"

  local response
  response=$(curl -s -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" -d "$(jq -n --arg cluster_id "$cluster_id" '{clusterId: $cluster_id, language: "sql"}')" "${api}/contexts/create")
  local context_id
  context_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null)
  if [ -z "$context_id" ]
  then
    logerror "❌ could not create an execution context on Databricks cluster ${cluster_id}: $response"
    exit 1
  fi

  response=$(curl -s -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" -d "$(jq -n --arg cluster_id "$cluster_id" --arg context_id "$context_id" --arg statement "$statement" '{clusterId: $cluster_id, contextId: $context_id, language: "sql", command: $statement}')" "${api}/commands/execute")
  local command_id
  command_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null)

  local status=""
  local cur_wait=0
  while [ ! -z "$command_id" ]
  do
    response=$(curl -s -G -H "Authorization: Bearer ${token}" --data-urlencode "clusterId=${cluster_id}" --data-urlencode "contextId=${context_id}" --data-urlencode "commandId=${command_id}" "${api}/commands/status")
    status=$(echo "$response" | jq -r '.status // empty' 2>/dev/null)
    if [ "$status" != "Queued" ] && [ "$status" != "Running" ] && [ "$status" != "Cancelling" ]
    then
      break
    fi
    if [[ "$cur_wait" -ge 120 ]]
    then
      break
    fi
    sleep 2
    cur_wait=$(( cur_wait+2 ))
  done
  curl -s -o /dev/null -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" -d "$(jq -n --arg cluster_id "$cluster_id" --arg context_id "$context_id" '{clusterId: $cluster_id, contextId: $context_id}')" "${api}/contexts/destroy"

  if [ "$status" != "Finished" ] || [ "$(echo "$response" | jq -r '.results.resultType // empty' 2>/dev/null)" == "error" ]
  then
    local message
    message=$(echo "$response" | jq -r '.results.summary // .results.cause // .error // empty' 2>/dev/null)
    logerror "❌ Databricks statement <$statement> ${status:-failed}: ${message:-$response}"
    exit 1
  fi
  echo "$response" | jq -c 'if (.results.data | type) == "array" then .results.data else [] end'
}

# Run one SQL statement on a Databricks SQL warehouse (SQL Statement Execution API), or on an
# all-purpose cluster when the http path is not a SQL warehouse one, and print
# its rows as a JSON array (data_array). Exits with the Databricks error message when it fails,
# for example "[INSUFFICIENT_PERMISSIONS] ... does not have SELECT on Table ..." or
# "PERMISSION_DENIED: ... does not have READ FILES on External Location ...".
function databricks_sql_statement () {
  local host="${1#https://}"
  host="${host%%/*}"
  local token="$2"
  local http_path="$3"
  local statement="$4"

  if [[ "$http_path" != *"/warehouses/"* ]]
  then
    databricks_cluster_sql_statement "$host" "$token" "${http_path##*/}" "$statement"
    return $?
  fi
  local warehouse_id="${http_path##*/}"

  local payload
  payload=$(jq -n --arg statement "$statement" --arg warehouse_id "$warehouse_id" '{statement: $statement, warehouse_id: $warehouse_id, wait_timeout: "50s", on_wait_timeout: "CANCEL"}')
  local response
  response=$(curl -s -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" -d "$payload" "https://${host}/api/2.0/sql/statements/")
  local state
  state=$(echo "$response" | jq -r '.status.state // empty' 2>/dev/null)
  if [ "$state" != "SUCCEEDED" ]
  then
    local message
    message=$(echo "$response" | jq -r '.status.error.message // .message // empty' 2>/dev/null)
    logerror "❌ Databricks statement <$statement> ${state:-failed}: ${message:-$response}"
    exit 1
  fi
  echo "$response" | jq -c '.result.data_array // []'
}

# Wait until a Databricks table holds the expected number of rows, and fail the test otherwise.
# The lag of the Databricks Delta Lake sink reaches 0 even when its COPY INTO fails (the staging
# S3 writer commits the offsets first), so the lag alone does not prove anything landed in the table.
function databricks_wait_for_table_rows () {
  local host="$1"
  local token="$2"
  local http_path="$3"
  local table="$4"
  local expected="$5"
  local max_wait="${6:-120}"

  local cur_wait=0
  local count=""
  log "⏳ Waiting up to $max_wait seconds for $expected rows in Databricks table $table"
  while true
  do
    local rows
    # logerror writes to stdout: print the captured output when the statement fails (exit in a subshell)
    if ! rows=$(databricks_sql_statement "$host" "$token" "$http_path" "SELECT COUNT(*) FROM $table")
    then
      echo "$rows"
      exit 1
    fi
    count=$(echo "$rows" | jq -r '.[0][0] // empty')
    if [ "$count" == "$expected" ]
    then
      log "✅ Databricks table $table has $count rows"
      return 0
    fi
    if [[ "$cur_wait" -ge "$max_wait" ]]
    then
      logerror "❌ Databricks table $table has ${count:-0} rows after $max_wait seconds, expected $expected"
      logerror "🔎 the connector log only shows 'java.sql.SQLException (SQLState=HY000, vendorCode=500051)' when COPY INTO fails: the real error is in the Query History of the SQL warehouse (COPY INTO $table)"
      exit 1
    fi
    sleep 10
    cur_wait=$(( cur_wait+10 ))
  done
}

if connect_cp_version_greater_than_8 && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "0.0.99"
then
     logwarn "minimal supported connector version is 1.0.0 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/8.0/connect/supported-connector-version.html#"
     exit 111
fi

cd ../../connect/connect-databricks-delta-lake-sink
if [ ! -f ${DIR}/SparkJDBC42.jar ]
then
     log "Getting SparkJDBC42.jar"
     curl --fail -sSL -O https://databricks-bi-artifacts.s3.us-east-2.amazonaws.com/simbaspark-drivers/jdbc/2.6.22/SimbaSparkJDBC42-2.6.22.1040.zip
     unzip SimbaSparkJDBC42-2.6.22.1040.zip
     rm -rf docs EULA.txt
     rm -f SimbaSparkJDBC42-2.6.22.1040.zip
fi
cd -

DATABRICKS_AWS_BUCKET_NAME=${DATABRICKS_AWS_BUCKET_NAME:-$1}
DATABRICKS_AWS_BUCKET_REGION=${DATABRICKS_AWS_BUCKET_REGION:-$2}
DATABRICKS_AWS_STAGING_S3_ACCESS_KEY_ID=${DATABRICKS_AWS_STAGING_S3_ACCESS_KEY_ID:-$3}
DATABRICKS_AWS_STAGING_S3_SECRET_ACCESS_KEY=${DATABRICKS_AWS_STAGING_S3_SECRET_ACCESS_KEY:-$4}

DATABRICKS_SERVER_HOSTNAME=${DATABRICKS_SERVER_HOSTNAME:-$5}
DATABRICKS_HTTP_PATH=${DATABRICKS_HTTP_PATH:-$6}
DATABRICKS_TOKEN=${DATABRICKS_TOKEN:-$7}

if [ -z "$DATABRICKS_AWS_BUCKET_NAME" ]
then
     logerror "DATABRICKS_AWS_BUCKET_NAME is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

if [ -z "$DATABRICKS_AWS_BUCKET_REGION" ]
then
     logerror "DATABRICKS_AWS_BUCKET_REGION is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

if [ -z "$DATABRICKS_AWS_STAGING_S3_ACCESS_KEY_ID" ]
then
     logerror "DATABRICKS_AWS_STAGING_S3_ACCESS_KEY_ID is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

if [ -z "$DATABRICKS_AWS_STAGING_S3_SECRET_ACCESS_KEY" ]
then
     logerror "DATABRICKS_AWS_STAGING_S3_SECRET_ACCESS_KEY is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

if [ -z "$DATABRICKS_SERVER_HOSTNAME" ]
then
     logerror "DATABRICKS_SERVER_HOSTNAME is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

if [ -z "$DATABRICKS_HTTP_PATH" ]
then
     logerror "DATABRICKS_HTTP_PATH is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

if [ -z "$DATABRICKS_TOKEN" ]
then
     logerror "DATABRICKS_TOKEN is not set. Export it as environment variable or pass it as argument"
     exit 1
fi


cd ../../connect/connect-databricks-delta-lake-sink

# Copy JAR files to confluent-hub
mkdir -p ../../confluent-hub/confluentinc-kafka-connect-databricks-delta-lake/lib/
cp ../../connect/connect-databricks-delta-lake-sink/SparkJDBC42.jar ../../confluent-hub/confluentinc-kafka-connect-databricks-delta-lake/lib/SparkJDBC42.jar
cd -
databricks_ensure_sql_warehouse_running "$DATABRICKS_SERVER_HOSTNAME" "$DATABRICKS_TOKEN" "$DATABRICKS_HTTP_PATH"

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

log "Not emptying the shared staging bucket, only the staged files of the topic of this run are removed at the end"

# one table per user: the workspace is shared, and a table created by someone else
# makes COPY INTO fail with [INSUFFICIENT_PERMISSIONS] ... does not have SELECT on Table
# one topic per run: the connector skips (and never auto-creates the table for) records whose offset
# is not above a file left under topics/<topic>/ in the shared staging bucket by an earlier run
# the environment is in the name: CI runs this example in the plaintext and cfk jobs of the same run, at the same time
DATABRICKS_SUFFIX="$(echo "${USER:-playground}_${GITHUB_RUN_NUMBER:-$(date +%s)}_${TAG_BASE}_${PLAYGROUND_ENVIRONMENT}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '_')"
DATABRICKS_TOPIC="pageviews_${DATABRICKS_SUFFIX}"
DATABRICKS_TABLE_NAME="pageviews_${DATABRICKS_SUFFIX}"

log "Sending messages to topic ${DATABRICKS_TOPIC}"
playground topic produce --topic "${DATABRICKS_TOPIC}" --nb-messages 100 << 'EOF'
{
     "namespace": "ksql",
     "name": "pageviews",
     "type": "record",
     "fields": [
          {"name": "viewtime", "type": "long"},
          {"name": "userid", "type": "string"},
          {"name": "pageid", "type": "string"}
     ]
}
EOF

log "Creating Databricks Delta Lake Sink connector, writing to table ${DATABRICKS_TABLE_NAME}"
playground connector create-or-update --connector databricks-delta-lake-sink  << EOF
{
     "connector.class": "io.confluent.connect.databricks.deltalake.DatabricksDeltaLakeSinkConnector",
     "topics": "${DATABRICKS_TOPIC}",
     "s3.region": "$DATABRICKS_AWS_BUCKET_REGION",
     "key.converter": "org.apache.kafka.connect.storage.StringConverter",
     "value.converter": "io.confluent.connect.avro.AvroConverter",
     "value.converter.schema.registry.url": "http://schema-registry:8081",
     "confluent.topic.bootstrap.servers": "broker:9092",
     "confluent.topic.replication.factor":1,
     "delta.lake.host.name": "$DATABRICKS_SERVER_HOSTNAME",
     "delta.lake.http.path": "$DATABRICKS_HTTP_PATH",
     "delta.lake.token": "$DATABRICKS_TOKEN",
     "delta.lake.topic2table.map": "${DATABRICKS_TOPIC}:${DATABRICKS_TABLE_NAME}",
     "delta.lake.table.auto.create": "true",
     "staging.s3.access.key.id": "$DATABRICKS_AWS_STAGING_S3_ACCESS_KEY_ID",
     "staging.s3.secret.access.key": "$DATABRICKS_AWS_STAGING_S3_SECRET_ACCESS_KEY",
     "staging.bucket.name": "$DATABRICKS_AWS_BUCKET_NAME",
     "flush.interval.ms": "100",
     "tasks.max": "1"
}
EOF

sleep 30

playground connector show-lag --max-wait 120

log "Verifying that the 100 records are in table ${DATABRICKS_TABLE_NAME} (the lag reaches 0 even when the COPY INTO fails)"
databricks_wait_for_table_rows "$DATABRICKS_SERVER_HOSTNAME" "$DATABRICKS_TOKEN" "$DATABRICKS_HTTP_PATH" "default.${DATABRICKS_TABLE_NAME}" 100

log "Dropping table ${DATABRICKS_TABLE_NAME} and removing the staged files of topic ${DATABRICKS_TOPIC}, as both are only for this run"
if ! drop_output=$(databricks_sql_statement "$DATABRICKS_SERVER_HOSTNAME" "$DATABRICKS_TOKEN" "$DATABRICKS_HTTP_PATH" "DROP TABLE IF EXISTS default.${DATABRICKS_TABLE_NAME}")
then
     echo "$drop_output"
     logwarn "🧱 could not drop table ${DATABRICKS_TABLE_NAME}"
fi
set +e
(
     export AWS_ACCESS_KEY_ID="$DATABRICKS_AWS_STAGING_S3_ACCESS_KEY_ID"
     export AWS_SECRET_ACCESS_KEY="$DATABRICKS_AWS_STAGING_S3_SECRET_ACCESS_KEY"
     export AWS_SESSION_TOKEN=""
     aws s3 rm "s3://${DATABRICKS_AWS_BUCKET_NAME}/topics/${DATABRICKS_TOPIC}/" --recursive --region $DATABRICKS_AWS_BUCKET_REGION
)
set -e
