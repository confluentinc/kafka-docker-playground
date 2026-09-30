#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

# DIAG (drop before PR): the agent's egress IP shares Docker Hub's anonymous pull quota with
# other traffic; wait (max 40 min) until enough is left for this test's pulls instead of
# failing on 429 (HEAD requests don't consume quota)
for DIAG_I in $(seq 1 40)
do
     DIAG_HUB_TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" | sed -E 's/.*"token":"([^"]+)".*/\1/')
     DIAG_HUB_LEFT=$(curl -s --head -H "Authorization: Bearer ${DIAG_HUB_TOKEN}" https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest | tr -d '\r' | awk -F'[ ;]' 'tolower($1)=="ratelimit-remaining:"{print $2}')
     echo "DIAG-HUB remaining=${DIAG_HUB_LEFT:-?} (check ${DIAG_I})"
     if [ -n "$DIAG_HUB_LEFT" ] && [ "$DIAG_HUB_LEFT" -ge 12 ]; then break; fi
     sleep 60
done
unset DIAG_HUB_TOKEN

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

# s390x: the emulated x86 mongod otherwise counts 0 CPUs and aborts at startup
qemu_recreate_with_x86_cpuinfo mongodb

# mongod (emulated under QEMU on s390x) can take far longer to accept
# connections and to become primary, so wait for both instead of assuming
playground container logs --container mongodb --wait-for-log "Waiting for connections" --max-wait 600 || { docker container logs --tail=150 mongodb; exit 1; }

log "Initialize MongoDB replica set"
docker exec -i mongodb mongosh --eval 'rs.initiate({_id: "myuser", members:[{_id: 0, host: "mongodb:27017"}]})'

playground container logs --container mongodb --wait-for-log "Transition to primary complete" --max-wait 300 || { docker container logs --tail=150 mongodb; exit 1; }

log "Create a user profile"
docker exec -i mongodb mongosh << EOF
use admin
db.createUser(
{
user: "myuser",
pwd: "mypassword",
roles: ["dbOwner"]
}
)
EOF

sleep 2

log "Sending messages to topic orders"
playground topic produce -t orders --nb-messages 1 << 'EOF'
{
  "type": "record",
  "name": "myrecord",
  "fields": [
    {
      "name": "id",
      "type": "int"
    },
    {
      "name": "product",
      "type": "string"
    },
    {
      "name": "quantity",
      "type": "int"
    },
    {
      "name": "price",
      "type": "float"
    }
  ]
}
EOF

playground topic produce -t orders --nb-messages 1 --forced-value '{"id":2,"product":"foo","quantity":2,"price":0.86583304}' << 'EOF'
{
  "type": "record",
  "name": "myrecord",
  "fields": [
    {
      "name": "id",
      "type": "int"
    },
    {
      "name": "product",
      "type": "string"
    },
    {
      "name": "quantity",
      "type": "int"
    },
    {
      "name": "price",
      "type": "float"
    }
  ]
}
EOF

log "Creating MongoDB sink connector"
playground connector create-or-update --connector mongodb-sink  << EOF
{
    "connector.class" : "com.mongodb.kafka.connect.MongoSinkConnector",
    "tasks.max" : "1",
    "connection.uri" : "mongodb://myuser:mypassword@mongodb:27017",
    "database":"inventory",
    "collection":"customers",
    "topics":"orders"
}
EOF

sleep 10

log "View record"
docker exec -i mongodb mongosh << EOF
use inventory
db.customers.find().pretty();
EOF

docker exec -i mongodb mongosh << EOF > output.txt
use inventory
db.customers.find().pretty();
EOF
grep "foo" output.txt
rm output.txt