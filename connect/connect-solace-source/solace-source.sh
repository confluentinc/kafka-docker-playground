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

function wait_for_solace () {
     MAX_WAIT=240
     CUR_WAIT=0
     log "⌛ Waiting up to $MAX_WAIT seconds for Solace to startup"
     docker container logs solace > /tmp/out.txt 2>&1
     while ! grep "Running pre-startup checks" /tmp/out.txt > /dev/null;
     do
          sleep 10
          docker container logs solace > /tmp/out.txt 2>&1
          CUR_WAIT=$(( CUR_WAIT+10 ))
          if [[ "$CUR_WAIT" -gt "$MAX_WAIT" ]]; then
               echo -e "\nERROR: The logs in all connect containers do not show 'Running pre-startup checks' after $MAX_WAIT seconds. Please troubleshoot with 'docker container ps' and 'playground container logs --open --container <container>'.\n"
               exit 1
          fi
     done
     log "Solace is started!"
     sleep 30
}

cd ../../connect/connect-solace-source
if [ ! -f ${DIR}/sol-jms-10.6.4.jar ]
then
     log "Downloading sol-jms-10.6.4.jar"
     # curl, not wget: the s390x Semaphore agent image ships curl but not
     # wget, so wget fails here with "wget: command not found". curl is
     # present on every agent (the pipeline prologue already uses it) and is
     # the more common choice across the KDP connector scripts anyway.
     curl --fail -sSL -O https://repo1.maven.org/maven2/com/solacesystems/sol-jms/10.6.4/sol-jms-10.6.4.jar
fi
cd -

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"

wait_for_solace
log "Solace UI is accessible at http://127.0.0.1:8080 (admin/admin)"

log "Create the queue connector-quickstart in the default Message VPN using CLI"
# wait_for_solace only greps for "Running pre-startup checks", the FIRST line
# Solace emits -- it is not a readiness signal. Issuing the config script
# before SolOS has finished starting fails in two different ways:
#     SolOS startup in progress, status: 'Starting daemon' / try again later
#     message-spool operational status is not AD-ACTIVE / Command Failed
# and neither is visible in the exit code, because the CLI returns 0 even when
# commands inside a -s script fail.
#
# Measured on a native broker: the marker appears at t+12s, the CLI accepts
# connections at t+17s, and `create queue` genuinely succeeds at t+22s -- so
# the fixed sleep in wait_for_solace covers the gap on amd64. On s390x that
# marker took 202s instead of 12s (~15x slower under emulation), stretching
# the same gap well past the sleep. "Running pre-startup checks: [ OK ]" is
# the only readiness-ish line the broker logs at all, so there is no later
# marker to wait on.
#
# So verify the END STATE instead of pattern-matching failure text: retry
# until `show queue` reports the queue. Matching error strings is what broke
# the earlier attempt at this -- the retry has to be narrow enough not to spin
# forever on "Queue already exists", which then let every other failure fall
# through as success and left the queue silently uncreated. Asserting the
# queue exists needs no such list, and is idempotent by construction: the
# create only runs while the queue is absent.
#
# Match on "Flags Legend" -- the header of the queue listing table -- NOT on
# the queue name. The CLI echoes each command it runs, so the queue name is
# present in the output whether or not the queue exists, and matching it just
# detects that the CLI is up. Verified against a live broker in all three
# states: spool not ready -> "not AD-ACTIVE"/"Command Failed", no header;
# spool ready but queue absent -> no header; queue present -> header.
printf 'enable\nshow queue connector-quickstart\n' > ${DIR}/show_queue_check_cmd
docker cp ${DIR}/show_queue_check_cmd solace:/usr/sw/jail/cliscripts/show_queue_check_cmd
MAX_WAIT=300
CUR_WAIT=0
until docker exec solace bash -c "/usr/sw/loads/currentload/bin/cli -A -s cliscripts/show_queue_check_cmd" 2>&1 | grep -q "Flags Legend"
do
     if [[ "$CUR_WAIT" -gt "$MAX_WAIT" ]]; then
          logerror "queue connector-quickstart did not exist after $MAX_WAIT seconds"
          cat /tmp/solace-cli.log
          exit 1
     fi
     docker exec solace bash -c "/usr/sw/loads/currentload/bin/cli -A -s cliscripts/create_queue_cmd" > /tmp/solace-cli.log 2>&1
     sleep 5
     CUR_WAIT=$(( CUR_WAIT+5 ))
done
cat /tmp/solace-cli.log
log "queue connector-quickstart confirmed present after ${CUR_WAIT}s"

log "Publish messages to the Solace queue using the REST endpoint"

for i in 1000 1001 1002
do
     curl -X POST -d "m1" http://localhost:9000/Queue/connector-quickstart -H "Content-Type: text/plain" -H "Solace-Message-ID: $i"
done

log "Creating Solace source connector"
playground connector create-or-update --connector solace-source  << EOF
{
     "connector.class": "io.confluent.connect.solace.SolaceSourceConnector",
     "tasks.max": "1",
     "kafka.topic": "from-solace-messages",
     "solace.host": "smf://solace:55555",
     "solace.username": "admin",
     "solace.password": "admin",
     "jms.destination.type": "queue",
     "jms.destination.name": "connector-quickstart",
     "key.converter": "org.apache.kafka.connect.storage.StringConverter",
     "value.converter": "org.apache.kafka.connect.storage.StringConverter",
     "confluent.topic.bootstrap.servers": "broker:9092",
     "confluent.topic.replication.factor": "1"
}
EOF

log "Verifying topic from-solace-messages"
playground topic consume --topic from-solace-messages --min-expected-messages 2 --timeout 60
