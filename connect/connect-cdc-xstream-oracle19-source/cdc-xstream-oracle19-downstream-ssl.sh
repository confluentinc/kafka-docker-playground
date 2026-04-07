#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

source ${DIR}/../../scripts/utils.sh

# Parameterized downstream capture TLS test script (one-way only).
#
# Environment variables:
#   SOURCE_TLS_MODE      - disable | one-way  (default: one-way)
#   DOWNSTREAM_TLS_MODE  - disable | one-way  (default: one-way)
#
# Wallets are always separate per database. No shared wallet support.
#
# Test matrix:
#   #1:  SOURCE_TLS_MODE=disable  DOWNSTREAM_TLS_MODE=disable   (baseline)
#   #2:  SOURCE_TLS_MODE=one-way  DOWNSTREAM_TLS_MODE=disable   (source wallet only)
#   #3:  SOURCE_TLS_MODE=disable  DOWNSTREAM_TLS_MODE=one-way   (downstream wallet only)
#   #4:  SOURCE_TLS_MODE=one-way  DOWNSTREAM_TLS_MODE=one-way   (separate wallets)
#
# Pre-built downstream capture Oracle images with TLS already configured.
# These images have databases already created with all XStream downstream capture
# configuration baked in (redo transport, capture process, outbound server, users, etc.)
# AND TLS wallets/listener pre-configured on port 2484.
# TCP listener on port 1521 is also available (used when TLS is disabled).
#
# Source DB:
#   SID: SRCCDB, PDB: SRCPDB1, DB_UNIQUE_NAME: SRCCDB_DB, db_domain: EXAMPLE.COM
#   Service name: SRCCDB_DB.EXAMPLE.COM (CDB), SRCPDB1.EXAMPLE.COM (PDB)
#   TNS alias: "capcdb" resolves to downstream host (used by LOG_ARCHIVE_DEST_2 for redo transport)
#   Users: c##xstrmadmin (XStream admin), c##xstrmuser (XStream connect), dbuser (schema user in PDB)
#   TLS: server wallet at /opt/oracle/oradata/dbconfig/SRCCDB/wallet, TCPS listener on port 2484
#        one-way client wallet at /opt/oracle/oradata/oneway_client_wallet
#
# Capture/Downstream DB:
#   SID: CAPCDB, PDB: CAPPDB1, db_domain: EXAMPLE.COM
#   Service name: CAPCDB.EXAMPLE.COM
#   TNS alias: "srccdb" resolves to source host (used by database link for downstream capture)
#   Users: c##xstrmadmin (XStream admin), c##xstrmuser (XStream connect)
#   XStream: capture process "xs_capture", outbound server "xout"
#   TLS: server wallet at /opt/oracle/oradata/dbconfig/CAPCDB/wallet, TCPS listener on port 2484
#        one-way client wallet at /opt/oracle/oradata/oneway_client_wallet
#
# Docker network aliases "srccdb" and "capcdb" must match the TNS entries baked into the images.

SOURCE_TLS_MODE=${SOURCE_TLS_MODE:-"one-way"}
DOWNSTREAM_TLS_MODE=${DOWNSTREAM_TLS_MODE:-"one-way"}

# Validate inputs
if [[ "$SOURCE_TLS_MODE" != "disable" && "$SOURCE_TLS_MODE" != "one-way" ]]; then
     logerror "Invalid SOURCE_TLS_MODE: $SOURCE_TLS_MODE (must be disable or one-way)"
     exit 1
fi
if [[ "$DOWNSTREAM_TLS_MODE" != "disable" && "$DOWNSTREAM_TLS_MODE" != "one-way" ]]; then
     logerror "Invalid DOWNSTREAM_TLS_MODE: $DOWNSTREAM_TLS_MODE (must be disable or one-way)"
     exit 1
fi

log "TLS test configuration: SOURCE_TLS_MODE=$SOURCE_TLS_MODE, DOWNSTREAM_TLS_MODE=$DOWNSTREAM_TLS_MODE"

# Determine ports based on TLS modes
if [[ "$SOURCE_TLS_MODE" == "one-way" ]]; then
     SOURCE_PORT="2484"
else
     SOURCE_PORT="1521"
fi
if [[ "$DOWNSTREAM_TLS_MODE" == "one-way" ]]; then
     DOWNSTREAM_PORT="2484"
else
     DOWNSTREAM_PORT="1521"
fi

ORACLE_ECR_REPO="519856050701.dkr.ecr.us-west-2.amazonaws.com/docker/prod/confluentinc/cc-kafka-connect-oracle-cdc"

# Select Oracle images based on TLS modes
# disable -> -source-real / -capture-real (no TLS suffix)
# one-way -> -source-real-tls-oneway / -capture-real-tls-oneway
if [[ "$SOURCE_TLS_MODE" == "one-way" ]]; then
     export ORACLE_IMAGE_SRC="${ORACLE_ECR_REPO}:19.29.0-ee-source-real-tls-oneway"
else
     export ORACLE_IMAGE_SRC="${ORACLE_ECR_REPO}:19.29.0-ee-source-real"
fi

if [[ "$DOWNSTREAM_TLS_MODE" == "one-way" ]]; then
     export ORACLE_IMAGE_CAP="${ORACLE_ECR_REPO}:19.29.0-ee-capture-real-tls-oneway"
else
     export ORACLE_IMAGE_CAP="${ORACLE_ECR_REPO}:19.29.0-ee-capture-real"
fi

log "Using images: SRC=$ORACLE_IMAGE_SRC, CAP=$ORACLE_IMAGE_CAP"

if [ ! -z "$SQL_DATAGEN" ]
then
     cd ../../connect/connect-cdc-xstream-oracle19-source
     log "SQL_DATAGEN is set"
     for component in oracle-datagen
     do
     set +e
     log "Building jar for ${component}"
     docker run -i --rm -e KAFKA_CLIENT_TAG=$KAFKA_CLIENT_TAG -e TAG=$TAG_BASE -v "${PWD}/${component}":/usr/src/mymaven -v "$HOME/.m2":/root/.m2 -v "$PWD/../../scripts/settings.xml:/tmp/settings.xml" -v "${PWD}/${component}/target:/usr/src/mymaven/target" -w /usr/src/mymaven maven:3.9.11-eclipse-temurin-11 mvn -s /tmp/settings.xml -Dkafka.tag=$TAG -Dkafka.client.tag=$KAFKA_CLIENT_TAG package > /tmp/result.log 2>&1
     if [ $? != 0 ]
     then
          logerror "failed to build java component "
          tail -500 /tmp/result.log
          exit 1
     fi
     set -e
     done
     cd -
else
     log "SQL_DATAGEN is not set"
fi

cd ../../connect/connect-cdc-xstream-oracle19-source
if [ ! -d "lib/instantclient" ]
then
     if [ -z "${ZIP_FILE}" ]
     then
          if [ `uname -m` = "arm64" ]
          then
               ZIP_FILE="instantclient_19_25_arm64.zip"
          else
               ZIP_FILE="instantclient_19_25_x86.zip"
          fi
          get_3rdparty_file "${ZIP_FILE}"
     fi

     if [ ! -f ${PWD}/${ZIP_FILE} ]
     then
          logerror "${PWD}/${ZIP_FILE} is missing. It must be downloaded manually in order to acknowledge user agreement"
          logerror "You can download it from https://www.oracle.com/in/database/technologies/instant-client/downloads.html"
          exit 1
     fi

     unzip ${ZIP_FILE} -d lib
     mv lib/instantclient_* lib/instantclient
fi
cd -


cd ../../connect/connect-cdc-xstream-oracle19-source

# Copy JAR files to confluent-hub
mkdir -p ../../confluent-hub/confluentinc-kafka-connect-oracle-xstream-cdc-source/lib/
cp ../../connect/connect-cdc-xstream-oracle19-source/lib/instantclient/ojdbc8.jar ../../confluent-hub/confluentinc-kafka-connect-oracle-xstream-cdc-source/lib/ojdbc8.jar
cp ../../connect/connect-cdc-xstream-oracle19-source/lib/instantclient/xstreams.jar ../../confluent-hub/confluentinc-kafka-connect-oracle-xstream-cdc-source/lib/xstreams.jar

# Copy sqlnet.ora configuration file to confluent-hub for thick-client TLS
if [[ "$SOURCE_TLS_MODE" == "one-way" || "$DOWNSTREAM_TLS_MODE" == "one-way" ]]; then
     if [ -f ssl/client/sqlnet.ora ]; then
          mkdir -p ../../confluent-hub/confluentinc-kafka-connect-oracle-xstream-cdc-source/
          cp ssl/client/sqlnet.ora ../../confluent-hub/confluentinc-kafka-connect-oracle-xstream-cdc-source/sqlnet.ora
     fi
fi
cd -
PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.downstream-ssl.yml"

if ! (version_gt $CP_CONNECT_TAG "7.6.99")
then
     playground container change-jdk --version 17 --container connect
fi

# https://github.com/confluentinc/common-docker/pull/743 and https://github.com/adoptium/adoptium-support/issues/1285
set +e
playground container exec --root --command "sed -i "s/packages\.adoptium\.net/adoptium\.jfrog\.io/g" /etc/yum.repos.d/adoptium.repo"
set -e
playground container exec --root --command "microdnf -y install libaio"

if [ "$(uname -m)" = "arm64" ]
then
     :
else
     if version_gt $TAG_BASE "7.9.9"
     then
          playground container exec --root --command "microdnf -y install libnsl2"
          playground container exec --root --command "ln -s /usr/lib64/libnsl.so.3 /usr/lib64/libnsl.so.1"
     else
          playground container exec --root --command "ln -s /usr/lib64/libnsl.so.2 /usr/lib64/libnsl.so.1"
     fi
fi

playground container logs --container downstreamdb --wait-for-log "DATABASE IS READY TO USE" --max-wait 900
log "Downstream Oracle DB (CAPCDB) has started!"

playground container logs --container sourcedb --wait-for-log "DATABASE IS READY TO USE" --max-wait 900
log "Source Oracle DB (SRCCDB) has started!"

# =====================================================
# TLS WALLET SETUP
# =====================================================

if [[ "$SOURCE_TLS_MODE" == "disable" && "$DOWNSTREAM_TLS_MODE" == "disable" ]]; then
     log "TLS disabled on both source and downstream, skipping wallet setup"

else
     if [[ "$SOURCE_TLS_MODE" == "one-way" ]]; then
          log "🔏 copy one-way client cwallet.sso from sourcedb to connect container (source wallet)"
          playground container exec --root --command "mkdir -p /tmp/source_wallet"
          docker cp sourcedb:/opt/oracle/oradata/oneway_client_wallet/cwallet.sso /tmp/cwallet_source.sso
          docker cp /tmp/cwallet_source.sso connect:/tmp/source_wallet/cwallet.sso
          playground container exec --root --command "chown -R appuser /tmp/source_wallet"
          SOURCE_WALLET_PATH="/tmp/source_wallet/"
     fi

     if [[ "$DOWNSTREAM_TLS_MODE" == "one-way" ]]; then
          log "🔏 copy one-way client cwallet.sso from downstreamdb to connect container (downstream wallet)"
          playground container exec --root --command "mkdir -p /tmp/downstream_wallet"
          docker cp downstreamdb:/opt/oracle/oradata/oneway_client_wallet/cwallet.sso /tmp/cwallet_downstream.sso
          docker cp /tmp/cwallet_downstream.sso connect:/tmp/downstream_wallet/cwallet.sso
          playground container exec --root --command "chown -R appuser /tmp/downstream_wallet"
          DOWNSTREAM_WALLET_PATH="/tmp/downstream_wallet/"
     fi
fi

# =====================================================
# SOURCE DATABASE SETUP
# =====================================================

log "Checking and re-enabling redo transport on source database"
docker exec -i sourcedb bash -c "ORACLE_SID=SRCCDB;export ORACLE_SID;sqlplus /nolog" << EOF
     CONNECT sys/Admin123 AS SYSDBA
     SELECT DEST_NAME, STATUS, ERROR FROM V\$ARCHIVE_DEST WHERE DEST_ID = 2;
     ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_2=ENABLE SCOPE=BOTH;
     ALTER SYSTEM SWITCH LOGFILE;
     SELECT DEST_NAME, STATUS, ERROR FROM V\$ARCHIVE_DEST WHERE DEST_ID = 2;
EOF

log "Starting XStream capture process on downstream database"
docker exec -i downstreamdb bash -c "ORACLE_SID=CAPCDB;export ORACLE_SID;sqlplus /nolog" << EOF
     CONNECT sys/Admin123 AS SYSDBA
     BEGIN
          DBMS_CAPTURE_ADM.START_CAPTURE(capture_name => 'xs_capture');
     END;
     /
EOF

log "Grant CREATE TRIGGER to dbuser on source PDB"
docker exec -i sourcedb bash -c "ORACLE_SID=SRCCDB;export ORACLE_SID;sqlplus /nolog" << EOF
     CONNECT sys/Admin123 AS SYSDBA
     ALTER SESSION SET CONTAINER = SRCPDB1;
     GRANT CREATE TRIGGER TO dbuser;
EOF

log "Create CUSTOMERS table and insert initial data on source database"
docker exec -i sourcedb sqlplus dbuser/mypassword@//localhost:1521/SRCPDB1.EXAMPLE.COM << EOF

     create table CUSTOMERS (
          id NUMBER(10) GENERATED BY DEFAULT ON NULL AS IDENTITY (START WITH 42) NOT NULL PRIMARY KEY,
          first_name VARCHAR(50),
          last_name VARCHAR(50),
          email VARCHAR(50),
          gender VARCHAR(50),
          club_status VARCHAR(20),
          comments VARCHAR(90),
          create_ts timestamp DEFAULT CURRENT_TIMESTAMP ,
          update_ts timestamp
     );

     CREATE OR REPLACE TRIGGER TRG_CUSTOMERS_UPD
     BEFORE INSERT OR UPDATE ON CUSTOMERS
     REFERENCING NEW AS NEW_ROW
     FOR EACH ROW
     BEGIN
     SELECT SYSDATE
          INTO :NEW_ROW.UPDATE_TS
          FROM DUAL;
     END;
     /

     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments) values ('Rica', 'Blaisdell', 'rblaisdell0@rambler.ru', 'Female', 'bronze', 'Universal optimal hierarchy');
     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments) values ('Ruthie', 'Brockherst', 'rbrockherst1@ow.ly', 'Female', 'platinum', 'Reverse-engineered tangible interface');
     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments) values ('Mariejeanne', 'Cocci', 'mcocci2@techcrunch.com', 'Female', 'bronze', 'Multi-tiered bandwidth-monitored capability');
     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments) values ('Hashim', 'Rumke', 'hrumke3@sohu.com', 'Male', 'platinum', 'Self-enabling 24/7 firmware');
     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments) values ('Hansiain', 'Coda', 'hcoda4@senate.gov', 'Male', 'platinum', 'Centralized full-range approach');
     exit;
EOF

# =====================================================
# BUILD AND CREATE CONNECTOR CONFIG
# =====================================================

# Print effective connection strings
SOURCE_PROTOCOL="TCP"
DOWNSTREAM_PROTOCOL="TCP"
if [[ "$SOURCE_TLS_MODE" == "one-way" ]]; then
     SOURCE_PROTOCOL="TCPS"
fi
if [[ "$DOWNSTREAM_TLS_MODE" == "one-way" ]]; then
     DOWNSTREAM_PROTOCOL="TCPS"
fi

log "=========================================================="
log "  SOURCE CONNECTION:"
log "    (DESCRIPTION=(ADDRESS=(PROTOCOL=${SOURCE_PROTOCOL})(HOST=sourcedb)(PORT=${SOURCE_PORT}))(CONNECT_DATA=(SERVICE_NAME=SRCCDB_DB.EXAMPLE.COM)))"
log "    TLS mode: ${SOURCE_TLS_MODE}, wallet: ${SOURCE_WALLET_PATH:-none}"
log "  DOWNSTREAM CONNECTION:"
log "    (DESCRIPTION=(ADDRESS=(PROTOCOL=${DOWNSTREAM_PROTOCOL})(HOST=downstreamdb)(PORT=${DOWNSTREAM_PORT}))(CONNECT_DATA=(SERVICE_NAME=CAPCDB.EXAMPLE.COM)))"
log "    TLS mode: ${DOWNSTREAM_TLS_MODE}, wallet: ${DOWNSTREAM_WALLET_PATH:-none}"
log "=========================================================="

# Build connector config dynamically based on TLS modes
SOURCE_TLS_CONFIG=""
if [[ "$SOURCE_TLS_MODE" == "one-way" ]]; then
     SOURCE_TLS_CONFIG="\"database.tls.mode\": \"one-way\",
	\"database.wallet.location\": \"${SOURCE_WALLET_PATH}\","
fi

DOWNSTREAM_TLS_CONFIG=""
if [[ "$DOWNSTREAM_TLS_MODE" == "one-way" ]]; then
     DOWNSTREAM_TLS_CONFIG="\"downstream.database.tls.mode\": \"one-way\",
	\"downstream.database.wallet.location\": \"${DOWNSTREAM_WALLET_PATH}\","
fi

log "Creating Oracle Xstream CDC source connector (source TLS=$SOURCE_TLS_MODE, downstream TLS=$DOWNSTREAM_TLS_MODE)"
playground connector create-or-update --connector cdc-xstream-oracle-source << EOF
{
	"connector.class": "io.confluent.connect.oracle.xstream.cdc.OracleXStreamSourceConnector",
	"database.hostname": "sourcedb",
	"database.port": "${SOURCE_PORT}",
	"database.dbname": "SRCCDB",
	"database.service.name": "SRCCDB_DB.EXAMPLE.COM",
	"database.user": "c##xstrmuser",
	"database.password": "mypassword",
	"database.pdb.name": "SRCPDB1",
	"database.out.server.name": "XOUT",
	"database.os.timezone": "UTC",
	${SOURCE_TLS_CONFIG}
	"table.include.list": "DBUSER[.]CUSTOMERS",
	"topic.prefix": "cflt",
	"downstream.database.hostname": "downstreamdb",
	"downstream.database.port": "${DOWNSTREAM_PORT}",
	"downstream.database.dbname": "CAPCDB",
	"downstream.database.service.name": "CAPCDB.EXAMPLE.COM",
	${DOWNSTREAM_TLS_CONFIG}
	"schema.history.internal.kafka.bootstrap.servers": "broker:9092",
	"schema.history.internal.kafka.topic": "__orcl-schema-changes.cflt",
	"confluent.license": "",
	"confluent.topic.bootstrap.servers": "broker:9092",
	"confluent.topic.replication.factor": "1",
	"database.processor.licenses": "1",

	"_comment:": "remove _ to use ExtractNewRecordState smt",
	"_transforms": "unwrap",
	"_transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState"
}
EOF

log "Waiting for downstream capture process to reach WAITING FOR TRANSACTION state"
MAX_WAIT=600
CUR_WAIT=0
while true; do
     STATE=$(docker exec -i downstreamdb bash -c 'ORACLE_SID=CAPCDB;export ORACLE_SID;sqlplus -s /nolog <<EOSQL
CONNECT sys/Admin123 AS SYSDBA
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SELECT STATE FROM GV\$XSTREAM_CAPTURE WHERE CAPTURE_NAME = '"'"'XS_CAPTURE'"'"';
EOSQL')
     log "Capture state: $STATE"
     if [[ "$STATE" == *"WAITING FOR TRANSACTION"* ]]; then
          log "Capture process is ready"
          break
     fi
     if [[ "$CUR_WAIT" -ge "$MAX_WAIT" ]]; then
          logerror "Capture process did not reach WAITING FOR TRANSACTION state after ${MAX_WAIT}s"
          exit 1
     fi
     sleep 30
     CUR_WAIT=$((CUR_WAIT+30))
done

# Verify actual network protocol used by connector sessions
log "=========================================================="
log "  VERIFYING ACTUAL CONNECTION PROTOCOLS"
log "=========================================================="

log "Checking source database sessions (expected: ${SOURCE_PROTOCOL}):"
docker exec -i sourcedb bash -c "ORACLE_SID=SRCCDB;export ORACLE_SID;sqlplus -s /nolog" << EOF
CONNECT sys/Admin123 AS SYSDBA
SET LINESIZE 200
COLUMN USERNAME FORMAT A15
COLUMN PROGRAM FORMAT A35
COLUMN NETWORK_SERVICE_BANNER FORMAT A90

-- Show all network banners for connector sessions (no filter - shows TCP, SSL, Crypto entries)
SELECT s.SID, s.USERNAME, n.NETWORK_SERVICE_BANNER
FROM V\$SESSION s
JOIN V\$SESSION_CONNECT_INFO n ON s.SID = n.SID AND s.SERIAL# = n.SERIAL#
WHERE s.USERNAME = 'C##XSTRMUSER'
AND n.NETWORK_SERVICE_BANNER IS NOT NULL;
EOF

log "Checking downstream database sessions (expected: ${DOWNSTREAM_PROTOCOL}):"
docker exec -i downstreamdb bash -c "ORACLE_SID=CAPCDB;export ORACLE_SID;sqlplus -s /nolog" << EOF
CONNECT sys/Admin123 AS SYSDBA
SET LINESIZE 200
COLUMN USERNAME FORMAT A15
COLUMN PROGRAM FORMAT A35
COLUMN NETWORK_SERVICE_BANNER FORMAT A90

-- Show all network banners for connector sessions (no filter - shows TCP, SSL, Crypto entries)
SELECT s.SID, s.USERNAME, n.NETWORK_SERVICE_BANNER
FROM V\$SESSION s
JOIN V\$SESSION_CONNECT_INFO n ON s.SID = n.SID AND s.SERIAL# = n.SERIAL#
WHERE s.USERNAME = 'C##XSTRMUSER'
AND n.NETWORK_SERVICE_BANNER IS NOT NULL;
EOF

log "=========================================================="

log "Insert 2 customers in CUSTOMERS table"
docker exec -i sourcedb sqlplus dbuser/mypassword@//localhost:1521/SRCPDB1.EXAMPLE.COM << EOF
     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments) values ('Frantz', 'Kafka', 'fkafka@confluent.io', 'Male', 'bronze', 'Evil is whatever distracts');
     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments) values ('Gregor', 'Samsa', 'gsamsa@confluent.io', 'Male', 'platinium', 'How about if I sleep a little bit longer and forget all this nonsense');
     exit;
EOF

log "Update CUSTOMERS with email=fkafka@confluent.io"
docker exec -i sourcedb sqlplus dbuser/mypassword@//localhost:1521/SRCPDB1.EXAMPLE.COM << EOF
     update CUSTOMERS set club_status = 'gold' where email = 'fkafka@confluent.io';
     exit;
EOF

log "Deleting CUSTOMERS with email=fkafka@confluent.io"
docker exec -i sourcedb sqlplus dbuser/mypassword@//localhost:1521/SRCPDB1.EXAMPLE.COM << EOF
     delete from CUSTOMERS where email = 'fkafka@confluent.io';
     exit;
EOF

sleep 10

log "Altering CUSTOMERS table with an optional column"
docker exec -i sourcedb sqlplus dbuser/mypassword@//localhost:1521/SRCPDB1.EXAMPLE.COM << EOF
     alter table CUSTOMERS add (country VARCHAR(50));
     exit;
EOF

sleep 1

log "Populating CUSTOMERS table after altering the structure"
docker exec -i sourcedb sqlplus dbuser/mypassword@//localhost:1521/SRCPDB1.EXAMPLE.COM << EOF
     insert into CUSTOMERS (first_name, last_name, email, gender, club_status, comments, country) values ('Josef', 'K', 'jk@confluent.io', 'Male', 'bronze', 'How is it even possible for someone to be guilty', 'Poland');
     update CUSTOMERS set club_status = 'silver' where email = 'gsamsa@confluent.io';
     update CUSTOMERS set club_status = 'gold' where email = 'gsamsa@confluent.io';
     update CUSTOMERS set club_status = 'gold' where email = 'jk@confluent.io';
     commit;
     exit;
EOF

sleep 10

log "Verifying topic cflt.DBUSER.CUSTOMERS: there should be 14 records"
# playground topic consume --topic cflt.DBUSER.CUSTOMERS --min-expected-messages 14 --timeout 120
playground topic get-number-records --topic cflt.DBUSER.CUSTOMERS

if [ ! -z "$SQL_DATAGEN" ]
then
     DURATION=10
     log "Injecting data for $DURATION minutes"
     docker exec sql-datagen bash -c "java ${JAVA_OPTS} -jar sql-datagen-1.0-SNAPSHOT-jar-with-dependencies.jar --host sourcedb --username dbuser --password mypassword --sidOrServerName sid --sidOrServerNameVal SRCCDB --maxPoolSize 10 --durationTimeMin $DURATION"
fi

log "You can use <playground connector oracle-cdc-xstream generate-report> to generate oracle cdc xstream connector diagnostics report"
log "You can use <playground connector oracle-cdc-xstream debug> to execute various SQL commands to debug xstream components"
