#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh


PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.yml"

log "create a topic testtopic with 30 seconds retention"
docker exec broker kafka-topics --create --topic testtopic --partitions 1 --replication-factor 1 --bootstrap-server broker:9092 --config retention.ms=30000

log "Describe new topic testtopic"
docker exec zookeeper kafka-topics --describe --topic testtopic --bootstrap-server broker:9092

sleep 1


i=0
while [ $i -le 50 ]
do
  log "Sending message $i to topic testtopic"
docker exec -i broker kafka-console-producer --bootstrap-server broker:9092 --topic testtopic << EOF
This is my message
EOF
  sleep 1
  ((i++))
done

sleep 10

docker exec broker ls -lrt /var/lib/kafka/data/testtopic-0/