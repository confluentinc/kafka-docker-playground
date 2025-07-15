#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if ! version_gt $TAG_BASE "6.9.9"; then
    logwarn "This can only be run with image or version greater than 7.0.0"
    exit 111
fi

if version_gt $TAG_BASE "7.9.9"; then
    logwarn "This example is not supported with CP 8.0 and later versions"
    logwarn "see deprecation https://docs.confluent.io/kafka-connectors/maprdb/current/overview.html" 
    exit 111
fi

if [ ! -z "$TAG_BASE" ] && version_gt $TAG_BASE "7.9.99" && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "1.0.99"
then
     logwarn "minimal supported connector version is 1.1.0 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

HPE_MAPR_EMAIL=${HPE_MAPR_EMAIL:-$1}
HPE_MAPR_TOKEN=${HPE_MAPR_TOKEN:-$2}

if [ -z "$HPE_MAPR_EMAIL" ]
then
     logerror "HPE_MAPR_EMAIL is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

if [ -z "$HPE_MAPR_TOKEN" ]
then
     logerror "HPE_MAPR_TOKEN is not set. Export it as environment variable or pass it as argument"
     exit 1
fi

# generate data file for externalizing secrets
sed -e "s|:HPE_MAPR_EMAIL:|$HPE_MAPR_EMAIL|g" \
    -e "s|:HPE_MAPR_TOKEN:|$HPE_MAPR_TOKEN|g" \
    ../../connect/connect-mapr-sink/maprtech.repo.template > ../../connect/connect-mapr-sink/maprtech.repo

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}

if [ ! -z $ENABLE_KRAFT ]
then
  # KRAFT mode
  playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose-kraft.yml"
else
  # Zookeeper mode
  playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"
fi

# useful script
# https://docs.ezmeral.hpe.com/datafabric-customer-managed/74/MapRContainerDevelopers/MapRContainerDevelopersOverview.html

log "Installing Mapr Client"

# RHEL
# required deps for mapr-client
docker exec -i --privileged --user root connect  bash -c "chmod a+rw /etc/yum.repos.d/maprtech.repo"
docker exec -i --privileged --user root connect  bash -c "rpm -i https://buildlogs.centos.org/c7.00.02/mtools/20140529191653/4.0.18-5.el7.x86_64/mtools-4.0.18-5.el7.x86_64.rpm"
docker exec -i --privileged --user root connect  bash -c "rpm -i https://downloads.storagecraft.com/_xafe/public/OneSystem/repo/el7/os/syslinux-4.05-15.el7.x86_64.rpm"

docker exec -i --privileged --user root connect  bash -c "yum -y install --disablerepo='Confluent*' --disablerepo='mapr*' jre-1.8.0-openjdk hostname findutils net-tools"

docker exec -i --privileged --user root connect  bash -c "wget --user=$HPE_MAPR_EMAIL --password=$HPE_MAPR_TOKEN -O mapr-pubkey.gpg https://package.ezmeral.hpe.com/releases/pub/maprgpg.key && rpm --import mapr-pubkey.gpg && yum -y update --disablerepo='Confluent*' && yum -y install mapr-client"

CONNECT_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' connect)
MAPR_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' mapr)

log "Login with maprlogin on mapr side (mapr)"
docker exec -i mapr bash -c "maprlogin password -user mapr" << EOF
mapr
EOF

log "Create table /mapr/maprdemo.mapr.io/maprtopic"
docker exec -i mapr bash -c "mapr dbshell" << EOF
create /mapr/maprdemo.mapr.io/maprtopic
EOF

sleep 60

log "Configure Mapr Client"
# Mapr sink is failing with CP 6.0 UBI8 #91
docker exec -i --privileged --user root connect bash -c "ln -sf /usr/lib/jvm/jre-1.8.0-openjdk /usr/lib/jvm/java-8-openjdk"
set +e
docker exec -i --privileged --user root connect bash -c "alternatives --remove java /usr/lib/jvm/zulu11/bin/java"
# with 7.3.3
docker exec -i --privileged --user root connect bash -c "alternatives --remove java /usr/lib/jvm/java-11-zulu-openjdk/bin/java"
set -e
docker exec -i --privileged --user root connect bash -c "chown -R appuser:appuser /opt/mapr"
set +e
log "It will fail the first time for some reasons.."
docker exec -i --privileged --user root connect bash -c "/opt/mapr/server/configure.sh -secure -N maprdemo.mapr.io -c -C $MAPR_IP -u appuser -g appuser"
docker exec -i --privileged --user root connect bash -c "rm -rf /opt/mapr/conf && cp -R /opt/mapr/conf.new /opt/mapr/conf"
set -e
docker exec -i --privileged --user root connect bash -c "/opt/mapr/server/configure.sh -secure -N maprdemo.mapr.io -c -C $MAPR_IP -u appuser -g appuser"

docker cp mapr:/opt/mapr/conf/ssl_truststore /tmp/ssl_truststore
docker cp /tmp/ssl_truststore connect:/opt/mapr/conf/ssl_truststore
docker exec -i --privileged --user root connect bash -c "chown -R appuser:appuser /opt/mapr"

log "Login with maprlogin on client side (connect)"
docker exec -i connect bash -c "maprlogin password -user mapr" << EOF
mapr
EOF

log "Sending messages to topic maprtopic"
playground topic produce -t maprtopic --nb-messages 3 --key "1" << 'EOF'
{"schema":{"type":"struct","fields":[{"type":"string","optional":false,"field":"record"}]},"payload":{"record":"record%g"}}
EOF

sleep 10

log "Creating Mapr sink connector"
playground connector create-or-update --connector mapr-sink  << EOF
{
    "connector.class": "io.confluent.connect.mapr.db.MapRDbSinkConnector",
    "tasks.max": "1",
    "mapr.table.map.maprtopic" : "/mapr/maprdemo.mapr.io/maprtopic",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "topics": "maprtopic"
}
EOF

sleep 70

log "Mapper UI MCS is running at https://127.0.0.1:8443 (mapr/map)"

log "Verify data is in Mapr"
docker exec -i mapr bash -c "mapr dbshell" > /tmp/result.log  2>&1 <<-EOF
find /mapr/maprdemo.mapr.io/maprtopic
EOF
cat /tmp/result.log
grep "_id" /tmp/result.log | grep "record1"
grep "_id" /tmp/result.log | grep "record2"
grep "_id" /tmp/result.log | grep "record3"