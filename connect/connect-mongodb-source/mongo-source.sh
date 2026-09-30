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

if is_s390x
then
     # QEMU's crypto instruction emulation makes the emulated mongod compute
     # SCRAM-SHA-256 wrong, so the natively running connector's login fails
     # ("Exception authenticating MongoCredential{mechanism=SCRAM-SHA-256, ...}");
     # force OpenSSL's software path as qemu_openssl_software_fallback_flag does
     # for docker run (passed through by docker-compose.plaintext.yml, unset elsewhere)
     export OPENSSL_ia32cap=0x0
fi

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

log "Creating MongoDB source connector"
playground connector create-or-update --connector mongodb-source  << EOF
{
     "connector.class" : "com.mongodb.kafka.connect.MongoSourceConnector",
     "tasks.max" : "1",
     "connection.uri" : "mongodb://myuser:mypassword@mongodb:27017",
     "database":"inventory",
     "collection":"customers",
     "topic.prefix":"mongo",
     "output.format.value": "schema",
     "output.schema.infer.value": "true"
}
EOF

sleep 5

# using pipeline:

# {
#     "connection.uri": "mongodb://myuser:mypassword@mongodb:27017",
#     "connector.class": "com.mongodb.kafka.connect.MongoSourceConnector",
#     "pipeline":"[{\"$match\": {\"ns.coll\": {\"$regex\": \"^(customers|goals)$\"}}}]",
#     "database":"inventory",
#     "tasks.max": "1",
#     "topic.prefix": "mongo"
# }

log "Insert a record"
docker exec -i mongodb mongosh << EOF
use inventory
db.customers.insert([
{ _id : 1, first_name : 'Bob', last_name : 'Hopper', email : 'thebob@example.com' }
]);
EOF

# log "Update a record"
# docker exec -i mongodb mongosh << EOF
# use inventory
# db.customers.updateOne(
#      { _id: 1 },
#      {
#            \$set: {
#                 email : "thebob2@example.com"
#                 }
#      }
     
# );
# EOF

log "View record"
docker exec -i mongodb mongosh << EOF
use inventory
db.customers.find().pretty();
EOF

sleep 5

log "Verifying topic mongo.inventory.customers"
playground topic consume --topic mongo.inventory.customers --min-expected-messages 1 --timeout 60
