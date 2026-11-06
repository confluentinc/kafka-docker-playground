#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if [ ! -z "$TAG_BASE" ] && version_gt $TAG_BASE "7.9.99" && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "1.1.99"
then
     logwarn "minimal supported connector version is 1.2.0 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

HIVE_INTEGRATION="true"
if version_gt $CONNECTOR_TAG "1.9.99"
then
  logwarn "HDFS3 Sink Connector versions 2.0.0 and above are compatible only with Hive Metastore versions 4.0.1 and later. Use hdfs3-sink-hive4.sh if you require hive integration"
  logwarn "skipping Hive integration in this example"
  HIVE_INTEGRATION="false"
fi

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

sleep 10

# Note in this simple example, if you get into an issue with permissions at the local HDFS level, it may be easiest to unlock the permissions unless you want to debug that more.
docker exec namenode bash -c "/opt/hadoop-3.1.3/bin/hdfs dfs -chmod 777  /"

log "Creating HDFS Sink connector with Hive integration"
playground connector create-or-update --connector hdfs3-sink  << EOF
{
  "connector.class":"io.confluent.connect.hdfs3.Hdfs3SinkConnector",
  "tasks.max":"1",
  "topics":"test_hdfs",
  "store.url":"hdfs://namenode:9000",
  "flush.size":"3",
  "hadoop.conf.dir":"/etc/hadoop/",
  "partitioner.class": "io.confluent.connect.storage.partitioner.DefaultPartitioner",
  "rotate.interval.ms":"120000",
  "hadoop.home":"/opt/hadoop-3.1.3/share/hadoop/common",
  "logs.dir":"/tmp",
  "hive.integration": "$HIVE_INTEGRATION",
  "hive.metastore.uris": "thrift://hive-metastore:9083",
  "hive.database": "testhive",
  "confluent.license": "",
  "confluent.topic.bootstrap.servers": "broker:9092",
  "confluent.topic.replication.factor": "1",
  "key.converter":"org.apache.kafka.connect.storage.StringConverter",
  "value.converter":"io.confluent.connect.avro.AvroConverter",
  "value.converter.schema.registry.url":"http://schema-registry:8081",
  "schema.compatibility":"BACKWARD"
}
EOF

log "Sending messages to topic test_hdfs"
playground topic produce -t test_hdfs --nb-messages 10 --forced-value '{"f1":"value%g"}' << 'EOF'
{
  "type": "record",
  "name": "myrecord",
  "fields": [
    {
      "name": "f1",
      "type": "string"
    }
  ]
}
EOF

sleep 10

log "Listing content of /topics/test_hdfs/partition=0 in HDFS"
docker exec namenode bash -c "/opt/hadoop-3.1.3/bin/hdfs dfs -ls /topics/test_hdfs/partition=0"

log "Getting one of the avro files locally and displaying content with avro-tools"
docker exec namenode bash -c "/opt/hadoop-3.1.3/bin/hadoop fs -copyToLocal /topics/test_hdfs/partition=0/test_hdfs+0+0000000000+0000000002.avro /tmp"
docker cp namenode:/tmp/test_hdfs+0+0000000000+0000000002.avro /tmp/

playground  tools read-avro-file --file /tmp/test_hdfs+0+0000000000+0000000002.avro


if ! version_gt $CONNECTOR_TAG "1.9.99"
then
  sleep 60
  log "Check data with beeline"
  docker exec -i hive-server beeline > /tmp/result.log  2>&1 <<-EOF
!connect jdbc:hive2://hive-server:10000/testhive
hive
hive
show create table test_hdfs;
select * from test_hdfs;
EOF
  cat /tmp/result.log
  grep "value1" /tmp/result.log
fi

# Parquet: the hdfs3 sink writes Parquet with SNAPPY compression (hard-coded in its
# ParquetRecordWriterProvider). snappy-java has no pure-Java fallback, so this exercises the
# connector's bundled native snappy library (e.g. on s390x). Reading the files back is covered
# by hdfs3-source.sh.
log "Creating HDFS Sink connector writing Parquet (snappy)"
playground connector create-or-update --connector hdfs3-sink-parquet  << EOF
{
  "connector.class":"io.confluent.connect.hdfs3.Hdfs3SinkConnector",
  "tasks.max":"1",
  "topics":"test_hdfs_parquet",
  "store.url":"hdfs://namenode:9000",
  "topics.dir":"/topics-parquet",
  "flush.size":"3",
  "hadoop.conf.dir":"/etc/hadoop/",
  "format.class":"io.confluent.connect.hdfs3.parquet.ParquetFormat",
  "partitioner.class": "io.confluent.connect.storage.partitioner.DefaultPartitioner",
  "rotate.interval.ms":"120000",
  "hadoop.home":"/opt/hadoop-3.1.3/share/hadoop/common",
  "logs.dir":"/tmp/parquet",
  "hive.integration": "false",
  "confluent.license": "",
  "confluent.topic.bootstrap.servers": "broker:9092",
  "confluent.topic.replication.factor": "1",
  "key.converter":"org.apache.kafka.connect.storage.StringConverter",
  "value.converter":"io.confluent.connect.avro.AvroConverter",
  "value.converter.schema.registry.url":"http://schema-registry:8081",
  "schema.compatibility":"BACKWARD"
}
EOF

log "Sending messages to topic test_hdfs_parquet"
playground topic produce -t test_hdfs_parquet --nb-messages 10 --forced-value '{"f1":"value%g"}' << 'EOF'
{
  "type": "record",
  "name": "myrecord",
  "fields": [
    {
      "name": "f1",
      "type": "string"
    }
  ]
}
EOF

sleep 10

log "Listing content of /topics-parquet/test_hdfs_parquet/partition=0 in HDFS"
docker exec namenode bash -c "/opt/hadoop-3.1.3/bin/hdfs dfs -ls /topics-parquet/test_hdfs_parquet/partition=0" | tee /tmp/hdfs3-sink-parquet-ls.log

log "Verifying that 3 Parquet files (10 records, flush.size=3) were committed"
nb_parquet_files=$(grep -c "\.parquet$" /tmp/hdfs3-sink-parquet-ls.log || true)
if [ "$nb_parquet_files" -lt 3 ]
then
     logerror "❌ expected at least 3 committed Parquet files, found $nb_parquet_files"
     exit 1
fi

log "Verifying that the Parquet sink task is still RUNNING"
playground connector status --connector hdfs3-sink-parquet 2>&1 | tee /tmp/hdfs3-sink-parquet-status.log
if grep -q "FAILED" /tmp/hdfs3-sink-parquet-status.log || ! grep -q "RUNNING" /tmp/hdfs3-sink-parquet-status.log
then
     logerror "❌ hdfs3-sink-parquet is not RUNNING"
     exit 1
fi