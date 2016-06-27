#!/bin/bash

# @author Michal Karm Babacek

# Debug logging
echo "STAT: `networkctl status`" | tee /opt/balancer/ip.log
echo "STAT ${BALANCER_NIC:-eth0}: `networkctl status ${BALANCER_NIC:-eth0}`" | tee /opt/balancer/ip.log

# Wait for the interface to wake up
TIMEOUT=20
MYIP=""
while (( "${MYIP}X" == "X" && "${TIMEOUT}" > 0 )); do
    echo "Loop ${TIMEOUT}" | tee /opt/balancer/ip.log
    MYIP="`networkctl status ${BALANCER_NIC:-eth0} | awk '{if($1~/Address:/){printf($2);}}'` | tr -d '[[:space:]]'"
    export MYIP
    echo "MYIP is $MYIP" | tee /opt/balancer/ip.log
    let TIMEOUT=$TIMEOUT-1
    if (( "${MYIP}X" != "X" )); then break; else sleep 1; fi
done
echo -e "MYIP: ${MYIP}\nMYNIC: ${BALANCER_NIC:-eth0}" | tee /opt/balancer/ip.log
if (( "${MYIP}X" == "X" )); then 
    echo "${BALANCER_NIC:-eth0} Interface error. " | tee /opt/balancer/ip.log
    exit 1
fi


# Wildfly runtime setup
CONTAINER_NAME=`echo ${DOCKERCLOUD_CONTAINER_FQDN}|sed 's/\([^\.]*\.[^\.]*\).*/\1/g'`
if [ "`echo \"${CONTAINER_NAME}\" | wc -c`" -gt 24 ]; then
    echo "ERROR: CONTAINER_NAME ${CONTAINER_NAME} must be up to 24 characters long."
    exit 1
fi

export JAVA_OPTS="-server \
                  -Xms${BALANCER_MS_RAM:-1g} \
                  -Xmx${BALANCER_MX_RAM:-1g} \
                  -XX:MetaspaceSize=96M \
                  -XX:MaxMetaspaceSize=256m \
                  -Djava.net.preferIPv4Stack=true \
                  -Djava.awt.headless=true \
                  -XX:+HeapDumpOnOutOfMemoryError \
                  -XX:HeapDumpPath=/opt/balancer"

${JBOSS_HOME}/bin/standalone.sh --admin-only &
TIMEOUT=5
while ((`grep -c "started in" ${JBOSS_HOME}/standalone/log/server.log` <= 0 && ${TIMEOUT} > 0 )); do
    echo Waiting for Wildfly startup...; sleep 1; let TIMEOUT=$TIMEOUT-1;
done; 
if (( $TIMEOUT == 0 )); then echo "Wildfly startup failed. We cannot continue."; exit 1; fi

${JBOSS_HOME}/bin/jboss-cli.sh --connect --commands=/interface=public:write-attribute(name=nic,value="${BALANCER_NIC:-eth0}")
${JBOSS_HOME}/bin/jboss-cli.sh --connect --commands=/subsystem=logging/console-handler=CONSOLE:write-attribute(name=level,value=${BALANCER_LOGLEVEL:-INFO})
${JBOSS_HOME}/bin/jboss-cli.sh --connect --commands=/subsystem=logging/root-logger=ROOT:write-attribute(name=level,value=${BALANCER_LOGLEVEL:-INFO})
${JBOSS_HOME}/bin/jboss-cli.sh --connect --commands=:shutdown

TIMEOUT=5
while ((`grep -c "stopped in" ${JBOSS_HOME}/standalone/log/server.log` <= 0 && ${TIMEOUT} > 0 )); do
     echo Waiting for Wildfly shutdown...; sleep 1; let TIMEOUT=$TIMEOUT-1;
done; 
if (( $TIMEOUT == 0 )); then echo "Wildfly shutdown failed. We cannot continue."; exit 1; fi


# Start the server
${JBOSS_HOME}/bin/standalone.sh \
 -c standalone.xml \
 -Djava.net.preferIPv4Stack=true \
 -Djboss.bind.address=${MYIP} \
 -Djboss.node.name="${CONTAINER_NAME}" \
 -Djboss.host.name="${DOCKERCLOUD_CONTAINER_FQDN}" \
 -Djboss.qualified.host.name="${DOCKERCLOUD_CONTAINER_FQDN}"

