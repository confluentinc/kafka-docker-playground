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

logwarn "Using JDBC with snowflake comes with caveats, see https://github.com/vdesabou/kafka-docker-playground/blob/084a41e82b2bb4ef0f2c98e46bd68cf2a9bf780d/connect/connect-jdbc-snowflake-source/README.md?plain=1#L8C1-L8C11"
logwarn "the example is no longer working with CP 8.0 getting:"

echo "
[2025-06-18 12:17:21,116] ERROR [jdbc-snowflake-source|task-0] Failed to get current time from DB using Generic and query 'SELECT CURRENT_TIMESTAMP' (io.confluent.connect.jdbc.dialect.GenericDatabaseDialect:587)
net.snowflake.client.jdbc.SnowflakeSQLLoggedException: JDBC driver internal error: Fail to retrieve row count for first arrow chunk: sun.misc.Unsafe or java.nio.DirectByteBuffer.<init>(long, int) not available.
        at net.snowflake.client.jdbc.SnowflakeResultSetSerializableV1.setFirstChunkRowCountForArrow(SnowflakeResultSetSerializableV1.java:1079) ~[snowflake-jdbc-3.13.16.jar:3.13.16]
        at net.snowflake.client.jdbc.SnowflakeResultSetSerializableV1.create(SnowflakeResultSetSerializableV1.java:562) ~[snowflake-jdbc-3.13.16.jar:3.13.16]
        at net.snowflake.client.jdbc.SnowflakeResultSetSerializableV1.create(SnowflakeResultSetSerializableV1.java:479) ~[snowflake-jdbc-3.13.16.jar:3.13.16]
        at net.snowflake.client.core.SFResultSetFactory.getResultSet(SFResultSetFactory.java:29) ~[snowflake-jdbc-3.13.16.jar:3.13.16]
        at net.snowflake.client.core.SFStatement.executeQueryInternal(SFStatement.java:220) ~[snowflake-jdbc-3.13.16.jar:3.13.16]
        at net.snowflake.client.core.SFStatement.executeQuery(SFStatement.java:135) ~[snowflake-jdbc-3.13.16.jar:3.13.16]
        at net.snowflake.client.core.SFStatement.execute(SFStatement.java:767) ~[snowflake-jdbc-3.13.16.jar:3.13.16]
        at net.snowflake.client.core.SFStatement.execute(SFStatement.java:677) ~[snowflake-jdbc-3.13.16.jar:3.13.16]
        at net.snowflake.client.jdbc.SnowflakeStatementV1.executeQueryInternal(SnowflakeStatementV1.java:238) ~[snowflake-jdbc-3.13.16.jar:3.13.16]
        at net.snowflake.client.jdbc.SnowflakeStatementV1.executeQuery(SnowflakeStatementV1.java:133) ~[snowflake-jdbc-3.13.16.jar:3.13.16]
        at io.confluent.connect.jdbc.dialect.GenericDatabaseDialect.currentTimeOnDB(GenericDatabaseDialect.java:577) ~[kafka-connect-jdbc-10.8.4.jar:?]
        at io.confluent.connect.jdbc.source.TimestampIncrementingTableQuerier.endTimestampValue(TimestampIncrementingTableQuerier.java:258) ~[kafka-connect-jdbc-10.8.4.jar:?]
        at io.confluent.connect.jdbc.source.TimestampIncrementingCriteria.setQueryParametersTimestampIncrementing(TimestampIncrementingCriteria.java:147) ~[kafka-connect-jdbc-10.8.4.jar:?]
        at io.confluent.connect.jdbc.source.TimestampIncrementingCriteria.setQueryParameters(TimestampIncrementingCriteria.java:134) ~[kafka-connect-jdbc-10.8.4.jar:?]
        at io.confluent.connect.jdbc.source.TimestampIncrementingTableQuerier.executeQuery(TimestampIncrementingTableQuerier.java:218) ~[kafka-connect-jdbc-10.8.4.jar:?]
        at io.confluent.connect.jdbc.source.TimestampIncrementingTableQuerier.maybeStartQuery(TimestampIncrementingTableQuerier.java:169) ~[kafka-connect-jdbc-10.8.4.jar:?]
        at io.confluent.connect.jdbc.source.JdbcSourceTask.poll(JdbcSourceTask.java:503) ~[kafka-connect-jdbc-10.8.4.jar:?]
        at org.apache.kafka.connect.runtime.AbstractWorkerSourceTask.poll(AbstractWorkerSourceTask.java:498) ~[connect_runtime_runtime-project.jar:?]
        at org.apache.kafka.connect.runtime.AbstractWorkerSourceTask.execute(AbstractWorkerSourceTask.java:370) ~[connect_runtime_runtime-project.jar:?]
        at org.apache.kafka.connect.runtime.WorkerTask.doRun(WorkerTask.java:266) ~[connect_runtime_runtime-project.jar:?]
        at org.apache.kafka.connect.runtime.WorkerTask.run(WorkerTask.java:322) ~[connect_runtime_runtime-project.jar:?]
        at org.apache.kafka.connect.runtime.AbstractWorkerSourceTask.run(AbstractWorkerSourceTask.java:83) ~[connect_runtime_runtime-project.jar:?]
        at org.apache.kafka.connect.runtime.isolation.Plugins.lambda$withClassLoader$7(Plugins.java:356) ~[connect_runtime_runtime-project.jar:?]
        at java.base/java.util.concurrent.Executors$RunnableAdapter.call(Executors.java:572) ~[?:?]
        at java.base/java.util.concurrent.FutureTask.run(FutureTask.java:317) ~[?:?]
        at java.base/java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1144) ~[?:?]
        at java.base/java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:642) ~[?:?]
        at java.base/java.lang.Thread.run(Thread.java:1583) [?:?]"

logwarn "upgrading driver fixes this issue, but then we get another issue with timestamp column, see below JDBC type 2014 (TIMESTAMPTZ) not currently supported"

username=$(whoami)
uppercase_username=$(echo $username | tr '[:lower:]' '[:upper:]')

PLAYGROUND_DB=PG_DB_${uppercase_username}${TAG}
PLAYGROUND_DB=${PLAYGROUND_DB//[-._]/}

PLAYGROUND_WAREHOUSE=PG_WH_${uppercase_username}${TAG}
PLAYGROUND_WAREHOUSE=${PLAYGROUND_WAREHOUSE//[-._]/}

PLAYGROUND_CONNECTOR_ROLE=PG_ROLE_${uppercase_username}${TAG}
PLAYGROUND_CONNECTOR_ROLE=${PLAYGROUND_CONNECTOR_ROLE//[-._]/}

PLAYGROUND_USER=PG_USER_${uppercase_username}${TAG}
PLAYGROUND_USER=${PLAYGROUND_USER//[-._]/}

cd ../../connect/connect-jdbc-snowflake-source
if [ ! -f ${PWD}/snowflake-jdbc-3.24.2.jar ]
then
     # newest versions do not work well with timestamp date, getting:
     # WARN JDBC type 2014 (TIMESTAMPIZ) not currently supported
     log "Downloading snowflake-jdbc-3.24.2.jar"
     wget -q https://repo1.maven.org/maven2/net/snowflake/snowflake-jdbc/3.24.2/snowflake-jdbc-3.24.2.jar

     # Any client driver version lower than what is listed below will be out of support as of February 1, 2024 based on the Snowflake Support policy https://go.snowflake.net/MjUyLVJGTy0yMjcAAAGWh1BWRfzuIKlEygL2SdqHsjvjZNQtWweD5pNexBO1BjoOYgzGFPj8zryM-ZcQLWuqmjI6kY4=
     # Snowflake JDBC Driver 3.13.27
fi
cd -

SNOWFLAKE_ACCOUNT_NAME=${SNOWFLAKE_ACCOUNT_NAME:-$1}
SNOWFLAKE_USERNAME=${SNOWFLAKE_USERNAME:-$2}
SNOWFLAKE_PASSWORD=${SNOWFLAKE_PASSWORD:-$3}

if [ -z "$SNOWFLAKE_ACCOUNT_NAME" ]
then
     logerror "SNOWFLAKE_ACCOUNT_NAME is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

if [ -z "$SNOWFLAKE_USERNAME" ]
then
     logerror "SNOWFLAKE_USERNAME is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

if [ -z "$SNOWFLAKE_PASSWORD" ]
then
     logerror "SNOWFLAKE_PASSWORD is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

# https://<account_name>.<region_id>.snowflakecomputing.com:443
SNOWFLAKE_URL="https://$SNOWFLAKE_ACCOUNT_NAME.snowflakecomputing.com"

cd ../../connect/connect-jdbc-snowflake-source
# using v1 PBE-SHA1-RC4-128, see https://community.snowflake.com/s/article/Private-key-provided-is-invalid-or-not-supported-rsa-key-p8--data-isn-t-an-object-ID
# Create encrypted Private key - keep this safe, do not share!
docker run -u0 --rm -v $PWD:/tmp vulhub/openssl:1.0.1c bash -c "openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -v1 PBE-SHA1-RC4-128 -out /tmp/snowflake_key.p8 -passout pass:confluent && chown -R $(id -u $USER):$(id -g $USER) /tmp/"
# Generate public key from private key. You can share your public key.
docker run -u0 --rm -v $PWD:/tmp vulhub/openssl:1.0.1c bash -c "openssl rsa -in /tmp/snowflake_key.p8 -pubout -out /tmp/snowflake_key.pub -passin pass:confluent && chown -R $(id -u $USER):$(id -g $USER) /tmp/"

if [ -z "$GITHUB_RUN_NUMBER" ]
then
    # not running with github actions
    # workaround for issue on linux, see https://github.com/vdesabou/kafka-docker-playground/issues/851#issuecomment-821151962
    chmod a+rw snowflake_key.p8
else
    # docker is run as runneradmin user, need to use sudo
    ls -lrt
    sudo chmod a+rw snowflake_key.p8
    ls -lrt
fi

RSA_PUBLIC_KEY=$(grep -v "BEGIN PUBLIC" snowflake_key.pub | grep -v "END PUBLIC"|tr -d '\n')
RSA_PRIVATE_KEY=$(grep -v "BEGIN ENCRYPTED PRIVATE KEY" snowflake_key.p8 | grep -v "END ENCRYPTED PRIVATE KEY"|tr -d '\n')
cd -

log "Create a Snowflake DB"
docker run --quiet --rm -i -e SNOWSQL_PWD="$SNOWFLAKE_PASSWORD" -e RSA_PUBLIC_KEY="$RSA_PUBLIC_KEY" kurron/snowsql --username $SNOWFLAKE_USERNAME -a $SNOWFLAKE_ACCOUNT_NAME << EOF
DROP DATABASE IF EXISTS $PLAYGROUND_DB;
CREATE OR REPLACE DATABASE $PLAYGROUND_DB COMMENT = 'Database for Docker Playground';
CREATE SCHEMA MYSCHEMA;
EOF

log "Create a Snowflake ROLE"
docker run --quiet --rm -i -e SNOWSQL_PWD="$SNOWFLAKE_PASSWORD" -e RSA_PUBLIC_KEY="$RSA_PUBLIC_KEY" kurron/snowsql --username $SNOWFLAKE_USERNAME -a $SNOWFLAKE_ACCOUNT_NAME << EOF
USE ROLE SECURITYADMIN;
DROP ROLE IF EXISTS $PLAYGROUND_CONNECTOR_ROLE;
CREATE ROLE $PLAYGROUND_CONNECTOR_ROLE;
GRANT USAGE ON DATABASE $PLAYGROUND_DB TO ROLE $PLAYGROUND_CONNECTOR_ROLE;
GRANT USAGE ON DATABASE $PLAYGROUND_DB TO ACCOUNTADMIN;
GRANT USAGE ON SCHEMA $PLAYGROUND_DB.MYSCHEMA TO ROLE $PLAYGROUND_CONNECTOR_ROLE;
GRANT ALL ON FUTURE TABLES IN SCHEMA $PLAYGROUND_DB.MYSCHEMA TO $PLAYGROUND_CONNECTOR_ROLE;
GRANT USAGE ON SCHEMA $PLAYGROUND_DB.MYSCHEMA TO ROLE ACCOUNTADMIN;
GRANT CREATE TABLE ON SCHEMA $PLAYGROUND_DB.MYSCHEMA TO ROLE $PLAYGROUND_CONNECTOR_ROLE;
GRANT CREATE STAGE ON SCHEMA $PLAYGROUND_DB.MYSCHEMA TO ROLE $PLAYGROUND_CONNECTOR_ROLE;
GRANT CREATE PIPE ON SCHEMA $PLAYGROUND_DB.MYSCHEMA TO ROLE $PLAYGROUND_CONNECTOR_ROLE;
GRANT ALL ON ALL SCHEMAS IN DATABASE $PLAYGROUND_DB TO ROLE $PLAYGROUND_CONNECTOR_ROLE;
GRANT ALL ON FUTURE SCHEMAS IN DATABASE $PLAYGROUND_DB TO ROLE $PLAYGROUND_CONNECTOR_ROLE;
GRANT ROLE $PLAYGROUND_CONNECTOR_ROLE TO ROLE ACCOUNTADMIN;
EOF

log "Create a Snowflake WAREHOUSE (for admin purpose as KafkaConnect is Serverless)"
docker run --quiet --rm -i -e SNOWSQL_PWD="$SNOWFLAKE_PASSWORD" -e RSA_PUBLIC_KEY="$RSA_PUBLIC_KEY" kurron/snowsql --username $SNOWFLAKE_USERNAME -a $SNOWFLAKE_ACCOUNT_NAME << EOF
USE ROLE SYSADMIN;
CREATE OR REPLACE WAREHOUSE $PLAYGROUND_WAREHOUSE
  WAREHOUSE_SIZE = 'XSMALL'
  WAREHOUSE_TYPE = 'STANDARD'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 1
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Warehouse for Kafka Playground';
GRANT USAGE ON WAREHOUSE $PLAYGROUND_WAREHOUSE TO ROLE $PLAYGROUND_CONNECTOR_ROLE;
EOF

log "Create a Snowflake USER"
docker run --quiet --rm -i -e SNOWSQL_PWD="$SNOWFLAKE_PASSWORD" -e RSA_PUBLIC_KEY="$RSA_PUBLIC_KEY" kurron/snowsql --username $SNOWFLAKE_USERNAME -a $SNOWFLAKE_ACCOUNT_NAME << EOF
USE ROLE USERADMIN;
DROP USER IF EXISTS $PLAYGROUND_USER;
CREATE USER $PLAYGROUND_USER
 PASSWORD = 'Password123!'
 LOGIN_NAME = $PLAYGROUND_USER
 DISPLAY_NAME = $PLAYGROUND_USER
 DEFAULT_WAREHOUSE = $PLAYGROUND_WAREHOUSE
 DEFAULT_ROLE = $PLAYGROUND_CONNECTOR_ROLE
 DEFAULT_NAMESPACE = $PLAYGROUND_DB
 MUST_CHANGE_PASSWORD = FALSE
 RSA_PUBLIC_KEY="$RSA_PUBLIC_KEY";
USE ROLE SECURITYADMIN;
GRANT ROLE $PLAYGROUND_CONNECTOR_ROLE TO USER $PLAYGROUND_USER;
EOF

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

log "Create table foo"
docker run --quiet --rm -i -e SNOWSQL_PWD="$SNOWFLAKE_PASSWORD" -e RSA_PUBLIC_KEY="$RSA_PUBLIC_KEY" kurron/snowsql --username $SNOWFLAKE_USERNAME -a $SNOWFLAKE_ACCOUNT_NAME << EOF
USE ROLE $PLAYGROUND_CONNECTOR_ROLE;
USE DATABASE $PLAYGROUND_DB;
USE SCHEMA MYSCHEMA;
USE WAREHOUSE $PLAYGROUND_WAREHOUSE;
create or replace sequence seq1;
create or replace table FOO (id number default seq1.nextval, f1 string, update_ts timestamp default current_timestamp());
insert into FOO (f1) values ('value1');
insert into FOO (f1) values ('value2');
insert into FOO (f1) values ('value3');
EOF

log "Create a view MYVIEWFORFOO"
docker run --quiet --rm -i -e SNOWSQL_PWD="$SNOWFLAKE_PASSWORD" -e RSA_PUBLIC_KEY="$RSA_PUBLIC_KEY" kurron/snowsql --username $SNOWFLAKE_USERNAME -a $SNOWFLAKE_ACCOUNT_NAME << EOF
USE ROLE $PLAYGROUND_CONNECTOR_ROLE;
USE DATABASE $PLAYGROUND_DB;
USE SCHEMA MYSCHEMA;
USE WAREHOUSE $PLAYGROUND_WAREHOUSE;
create or replace view MYVIEWFORFOO as select id,f1, convert_timezone('UTC', update_ts) as update_ts from FOO;
EOF

docker run --quiet --rm -i -e SNOWSQL_PWD="$SNOWFLAKE_PASSWORD" -e RSA_PUBLIC_KEY="$RSA_PUBLIC_KEY" kurron/snowsql --username $SNOWFLAKE_USERNAME -a $SNOWFLAKE_ACCOUNT_NAME << EOF
USE ROLE SECURITYADMIN;
grant select on view $PLAYGROUND_DB.MYSCHEMA.MYVIEWFORFOO to role $PLAYGROUND_CONNECTOR_ROLE;
EOF

# https://docs.snowflake.com/en/user-guide/jdbc-configure.html#jdbc-driver-connection-string
CONNECTION_URL="jdbc:snowflake://$SNOWFLAKE_ACCOUNT_NAME.snowflakecomputing.com/?warehouse=$PLAYGROUND_WAREHOUSE&db=$PLAYGROUND_DB&role=$PLAYGROUND_CONNECTOR_ROLE&schema=MYSCHEMA&user=$PLAYGROUND_USER&private_key_file=/tmp/snowflake_key.p8&private_key_file_pwd=confluent&tracing=ALL"
VIEW="$PLAYGROUND_DB.MYSCHEMA.MYVIEWFORFOO"

log "Creating JDBC Snowflake Source connector"
playground connector create-or-update --connector jdbc-snowflake-source  << EOF
{
     "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
     "tasks.max": "1",
     "connection.url": "$CONNECTION_URL",
     "table.whitelist": "$VIEW",
     "table.types": "VIEW",
     "mode": "timestamp+incrementing",
     "timestamp.column.name": "UPDATE_TS",
     "incrementing.column.name": "ID",
     "topic.prefix": "snowflake-",
     "validate.non.null":"false",
     "errors.log.enable": "true",
     "errors.log.include.messages": "true"
}
EOF

sleep 15

log "Verifying topic snowflake-MYVIEWFORFOO"
playground topic consume --topic snowflake-MYVIEWFORFOO --min-expected-messages 3 --timeout 60
