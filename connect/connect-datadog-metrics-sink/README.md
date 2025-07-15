# Datadog Metrics Sink connector


## Objective

Quickly test [Datadog Metrics Sink](https://docs.confluent.io/current/connect/kafka-connect-datadog-metrics/index.html#quick-start) connector.

## Prerequisites

Register for a [Datadog trial](https://app.datadoghq.com) if you don't already have an account (you can convert it to *Free plan* after the trial expires).

Create an API key (`DD_API_KEY`) and an Application key (`DD_APP_KEY`):

![Datadog metrics](Screenshot2.png)


**Important**: `COM` domain must be used

## How to run

Simply run:

```
$ just use <playground run> command and search for datadog-metrics-sink-sink<use tab key to activate fzf completion (see https://kafka-docker-playground.io/#/cli?id=%e2%9a%a1-setup-completion), otherwise use full path, or correct relative path> <DD_API_KEY> .sh in this folder

Note: you can also export these values as environment variable

```

## Details of what the script is doing

Sending messages to topic datadog-metrics-topic:

```bash
$ TIMESTAMP=`date +%s`
$ docker exec -i connect kafka-avro-console-producer --bootstrap-server broker:9092 --property schema.registry.url=http://schema-registry:8081 --topic datadog-metrics-topic --property value.schema='{"name": "metric","type": "record","fields": [{"name": "name","type": "string"},{"name": "type","type": "string"},{"name": "timestamp","type": "long"}, {"name": "dimensions", "type": {"name": "dimensions", "type": "record", "fields": [{"name": "host", "type":"string"}, {"name":"interval", "type":"int"}, {"name": "tag1", "type":"string"}]}},{"name": "values","type": {"name": "values","type": "record","fields": [{"name":"doubleValue", "type": "double"}]}}]}' << EOF
{"name":"perf.metric", "type":"rate","timestamp": $TIMESTAMP, "dimensions": {"host": "metric.host1", "interval": 1, "tag1": "testing-data"},"values": {"doubleValue": 5.639623848362502}}
EOF
```

Creating Datadog metrics sink connector:

```bash
$ curl -X PUT \
     -H "Content-Type: application/json" \
     --data '{
               "connector.class": "io.confluent.connect.datadog.metrics.DatadogMetricsSinkConnector",
               "tasks.max": "1",
               "key.converter":"org.apache.kafka.connect.storage.StringConverter",
               "value.converter":"io.confluent.connect.avro.AvroConverter",
               "value.converter.schema.registry.url":"http://schema-registry:8081",
               "confluent.topic.bootstrap.servers": "broker:9092",
               "confluent.topic.replication.factor":1,
               "datadog.api.key": "$DD_API_KEY",
               "datadog.domain": "COM",
               "reporter.bootstrap.servers": "broker:9092",
               "reporter.error.topic.name": "error-responses",
               "reporter.error.topic.replication.factor": 1,
               "reporter.result.topic.name": "success-responses",
               "reporter.result.topic.replication.factor": 1,
               "behavior.on.error": "fail",
               "topics": "datadog-metrics-topic"
          }' \
     http://localhost:8083/connectors/datadog-metrics-sink/config | jq .
```

Make sure `perf.metric` is present in Datadog
```
$ docker run -e DOGSHELL_API_KEY=$DD_API_KEY -e DOGSHELL_APP_KEY=$DD_APP_KEY dogshell:latest search query perf.metric
metrics perf.metric
```

Check the data is in Datadog:

![Datadog metrics](Screenshot1.png)

N.B: Control Center is reachable at [http://127.0.0.1:9021](http://127.0.0.1:9021])
