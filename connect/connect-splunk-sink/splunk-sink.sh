#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if [ ! -z "$TAG_BASE" ] && version_gt $TAG_BASE "7.9.99" && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "2.1.99"
then
     logwarn "minimal supported connector version is 2.2.0 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

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


SPLUNK_MAX_WAIT=600
if [ "$(uname -m)" = "s390x" ]
then
     # splunk/splunk has no s390x manifest and runs emulated under QEMU, where
     # its Ansible first-boot provisioning is much slower
     SPLUNK_MAX_WAIT=3600
fi
SECONDS=0
# DIAG (drop before PR): under QEMU, does root's `sudo -u splunk` really switch uid? (explains the root-start EACCES)
docker exec -u root splunk sh -c 'echo "root uid: $(id -u)"; echo "sudo -u splunk uid: $(sudo -n -u splunk id -u 2>&1)"; echo "ansible-style sudo -H -S -n -i -u splunk uid: $(sudo -H -S -n -i -u splunk id -u 2>&1 </dev/null)"' 2>&1 | sed 's/^/DIAG-PERM /' || true
# DIAG (drop before PR): can the image's default 'ansible' user sudo under QEMU (binfmt without the C flag)?
docker exec -u ansible splunk sh -c 'echo "ansible uid: $(id -u)"; echo "ansible sudo -n id -u: $(sudo -n id -u 2>&1)"' 2>&1 | sed 's/^/DIAG-PERM /' || true
# DIAG (drop before PR): poll marker + container state every 10s, progress line every 5 min,
# and dump ansible output + splunkd logs as soon as the container exits (or on timeout)
until docker logs splunk 2>&1 | grep -q "Ansible playbook complete, will begin streaming splunkd_stderr.log"
do
     DIAG_STATE=$(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' splunk 2>&1)
     if [ $((SECONDS % 300)) -lt 10 ]
     then
          echo "DIAG splunk t=${SECONDS}s state=${DIAG_STATE} stats=[$(docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' splunk 2>&1)] task=[$(docker logs splunk 2>&1 | grep -a -o 'TASK \[[^]]*\]' | tail -1)] ntasks=$(docker logs splunk 2>&1 | grep -a -c 'TASK \[')"
          docker logs splunk 2>&1 | grep -a -E "FAILED - RETRYING|fatal:|\"stderr\"|\"stdout\"" | tail -n 3 | cut -c1-400 | sed 's/^/DIAG-ansible /'
          docker exec splunk sh -c 'tail -n 4 /opt/splunk/var/log/splunk/splunkd_stderr.log; tail -n 6 /opt/splunk/var/log/splunk/splunkd.log' 2>&1 | cut -c1-300 | sed 's/^/DIAG-tail /'
     fi
     if [[ "$DIAG_STATE" != running* ]] || [ $SECONDS -gt $SPLUNK_MAX_WAIT ]
     then
          echo "DIAG splunk gave up t=${SECONDS}s state=${DIAG_STATE}"
          docker container logs --tail=250 splunk 2>&1 | sed 's/^/DIAG-LOG /'
          docker container logs splunk 2>&1 | grep -a -A60 "fatal:" | head -n 120 | cut -c1-400 | sed 's/^/DIAG-FATAL /'
          for f in splunkd_stderr.log splunkd.log; do
               docker cp splunk:/opt/splunk/var/log/splunk/$f /tmp/diag-$f >/dev/null 2>&1 && tail -n 60 /tmp/diag-$f | sed "s/^/DIAG-$f /"
          done
          # does the emulated x86 splunkd see the s390x host's /proc/cpuinfo (0 x86 "processor" lines)?
          grep -a -h -E "Detected [0-9]+ \(virtual\) CPUs|CPU|cpuinfo" /tmp/diag-splunkd.log 2>/dev/null | head -n 10 | cut -c1-300 | sed 's/^/DIAG-CPU /'
          grep -c "^processor" /proc/cpuinfo | sed 's/^/DIAG-CPU host x86-style processor lines: /'
          exit 1
     fi
     sleep 10
done
log "SPLUNK has started! (after ${SECONDS}s)"


log "Splunk UI is accessible at http://127.0.0.1:8000 (admin/password)"

# log "Setting minfreemb to 1Gb (by default 5Gb)"
# docker exec splunk bash -c 'sudo /opt/splunk/bin/splunk set minfreemb 1000 -auth "admin:password"'
# docker exec splunk bash -c 'sudo /opt/splunk/bin/splunk restart'
# sleep 60

log "Sending messages to topic splunk-qs"
playground topic produce -t splunk-qs --nb-messages 3 << 'EOF'
{"store":{"book":[{"category":"reference", "sold": false,"author":"Nigel Rees","title":"Sayings of the Century","price":8.95},{"category":"fiction","author":"Evelyn Waugh","title":"Sword of Honour","price":12.99},{"category":"fiction","author":"J. R. R. Tolkien","title":"The Lord of the Rings","act": null, "isbn":"0-395-19395-8","price":22.99}],"bicycle":{"color":"red","price":19.95}}}
EOF

log "Creating Splunk sink connector"
playground connector create-or-update --connector splunk-sink  << EOF
{
     "connector.class": "com.splunk.kafka.connect.SplunkSinkConnector",
     "tasks.max": "1",
     "topics": "splunk-qs",
     "splunk.indexes": "main",
     "splunk.hec.uri": "http://splunk:8088",
     "splunk.hec.token": "99582090-3ac3-4db1-9487-e17b17a05081",
     "splunk.hec.ssl.enforced": "false",
     "splunk.sourcetypes": "my_sourcetype",
     "value.converter":"org.apache.kafka.connect.json.JsonConverter",
     "value.converter.schemas.enable":"false"
}
EOF

log "Sleeping 80 seconds"
sleep 80

log "Verify data is in splunk"
docker exec splunk bash -c '/opt/splunk/bin/splunk search "source=\"http:splunk_hec_token\"" -auth "admin:password"' > /tmp/result.log  2>&1
cat /tmp/result.log
grep "Sword of Honour" /tmp/result.log
