#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

cd ../../connect/connect-lenses-active-mq-source
if [ ! -f ${DIR}/activemq-all-5.15.4.jar ]
then
     log "Downloading activemq-all-5.15.4.jar"
     wget -q https://repo1.maven.org/maven2/org/apache/activemq/activemq-all/5.15.4/activemq-all-5.15.4.jar
fi
cd -

if [ -z "$CONNECTOR_TAG" ]
then
    CONNECTOR_TAG=1.2.3
fi

if [ ! -f $PWD/kafka-connect-jms-${CONNECTOR_TAG}-2.1.0-all.jar ]
then
    curl -L -o kafka-connect-jms-${CONNECTOR_TAG}-2.1.0-all.tar.gz https://github.com/lensesio/stream-reactor/releases/download/${CONNECTOR_TAG}/kafka-connect-jms-${CONNECTOR_TAG}-2.1.0-all.tar.gz
    tar xvfz kafka-connect-jms-${CONNECTOR_TAG}-2.1.0-all.tar.gz
fi

export VERSION=$CONNECTOR_TAG
unset CONNECTOR_TAG

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.yml"


log "Creating Lenses JMS ActiveMQ source connector"
playground connector create-or-update --connector lenses-active-mq-source << EOF
{
     "connector.class": "com.datamountaineer.streamreactor.connect.jms.source.JMSSourceConnector",
     "connect.jms.kcql": "INSERT INTO MyKafkaTopicName SELECT * FROM myqueue WITHTYPE QUEUE WITHCONVERTER=\`com.datamountaineer.streamreactor.connect.converters.source.JsonSimpleConverter\`",
     "connect.jms.url": "tcp://activemq:61616",
     "connect.jms.initial.context.factory": "org.apache.activemq.jndi.ActiveMQInitialContextFactory",
     "connect.jms.connection.factory": "ConnectionFactory"
}
EOF

sleep 5

log "Sending messages to myqueue JMS queue:"
curl -XPOST -u admin:admin -d 'body={"u_name": "scissors", "u_price": 2.75, "u_quantity": 3}' http://localhost:8161/api/message/myqueue?type=queue

sleep 5

log "Verify we have received the data in MyKafkaTopicName topic"
playground topic consume --topic MyKafkaTopicName --min-expected-messages 1 --timeout 60
