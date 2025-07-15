# Data Diode (Source & Sink) connector



## Objective

Quickly test [ata Diode (Source & Sink)](https://docs.confluent.io/current/connect/kafka-connect-data-diode/index.html#data-diode-connector-source-and-sink-for-cp) connector.


## How to run

Simply run:

```
$ just use <playground run> command and search for datadiode.sh in this folder
```

## Details of what the script is doing

Creating DataDiode Source connector

```bash
$ curl -X PUT \
     -H "Content-Type: application/json" \
     --data '{
               "tasks.max": "1",
               "connector.class": "io.confluent.connect.diode.source.DataDiodeSourceConnector",
               "kafka.topic.prefix": "dest_",
               "key.converter": "org.apache.kafka.connect.converters.ByteArrayConverter",
               "value.converter": "org.apache.kafka.connect.converters.ByteArrayConverter",
               "header.converter": "org.apache.kafka.connect.converters.ByteArrayConverter",
               "diode.port": "3456",
               "diode.encryption.password": "supersecretpassword",
               "diode.encryption.salt": "secretsalt",
               "confluent.license": "",
               "confluent.topic.bootstrap.servers": "broker:9092",
               "confluent.topic.replication.factor": "1"
          }' \
     http://localhost:8083/connectors/datadiode-source/config | jq .
```

Creating DataDiode Sink connector

```bash
$ curl -X PUT \
     -H "Content-Type: application/json" \
     --data '{
               "connector.class": "io.confluent.connect.diode.sink.DataDiodeSinkConnector",
               "tasks.max": "1",
               "topics": "diode",
               "key.converter": "org.apache.kafka.connect.converters.ByteArrayConverter",
               "value.converter": "org.apache.kafka.connect.converters.ByteArrayConverter",
               "header.converter": "org.apache.kafka.connect.converters.ByteArrayConverter",
               "diode.host": "connect",
               "diode.port": "3456",
               "diode.encryption.password": "supersecretpassword",
               "diode.encryption.salt": "secretsalt",
               "confluent.license": "",
               "confluent.topic.bootstrap.servers": "broker:9092",
               "confluent.topic.replication.factor": "1"
          }' \
     http://localhost:8083/connectors/datadiode-sink/config | jq .
```

Send message to diode topic

```bash
$ seq -f "This is a message %g" 10 | docker exec -i broker kafka-console-producer --bootstrap-server broker:9092 --topic diode
```

Verifying topic dest_diode

```bash
playground topic consume --topic dest_diode --min-expected-messages 10 --timeout 60
```

N.B: Control Center is reachable at [http://127.0.0.1:9021](http://127.0.0.1:9021])
