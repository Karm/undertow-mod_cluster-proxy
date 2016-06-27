FROM fedora:24
MAINTAINER Michal Karm Babacek <karm@email.cz>
LABEL description="Undertow mod_cluster proxy example"

ENV DEPS            java-1.8.0-openjdk-devel.x86_64 unzip wget find jna.x86_64 jsch-agent-proxy-usocket-jna.noarch
ENV JBOSS_HOME      "/opt/balancer/wildfly"
ENV JAVA_HOME       "/usr/lib/jvm/java-1.8.0"

   
# Update and configure system
RUN dnf -y update && dnf -y install ${DEPS} && dnf clean all
RUN useradd -s /sbin/nologin balancer
RUN mkdir -p /opt/balancer && chown balancer /opt/balancer && chgrp balancer /opt/balancer && chmod ug+rwxs /opt/balancer

WORKDIR /opt/balancer
USER balancer


# Build Wildfly
ENV WILDFLY_GIT_TAG master
#ENV  WILDFLY_GIT_TAG 10.0.0.Final
ENV WILDFLY_GIT_DOWNLOAD https://github.com/wildfly/wildfly/archive/${WILDFLY_GIT_TAG}.zip

RUN wget ${WILDFLY_GIT_DOWNLOAD} && \
    unzip wildfly-${WILDFLY_GIT_TAG}.zip && rm -rf wildfly-${WILDFLY_GIT_TAG}.zip && \
    cd wildfly-${WILDFLY_GIT_TAG} && ./build.sh -DskipTests && \
      mv `find dist/target/ -maxdepth 1 -type d -name "wildfly-*"` ${JBOSS_HOME} && \
    cd .. && rm -rf wildfly-${WILDFLY_GIT_TAG}


# Configure Undertow mod_cluster proxy
ENV MOD_CLUSTER_MULTICAST_PORT 23399
ENV MOD_CLUSTER_MULTICAST_ADDRESS 224.0.1.106

EXPOSE 8080/tcp  # main http connector
EXPOSE ${MOD_CLUSTER_MULTICAST_PORT}/udp # balancer uses for advertising 

RUN (${JBOSS_HOME}/bin/standalone.sh --admin-only &) && TIMEOUT=5 && \
    while ((`grep -c "started in" ${JBOSS_HOME}/standalone/log/server.log` <= 0 && ${TIMEOUT} > 0 )); do \
      echo Waiting for Wildfly...; sleep 1; let TIMEOUT=$TIMEOUT-1; \
    done; \
    if (( $TIMEOUT == 0 ));then echo "Wildfly startup failed. We cannot continue."; exit 1; fi \
# Socket binding for sending messages
${JBOSS_HOME}/bin/jboss-cli.sh --connect --commands=/socket-binding-group=standard-sockets/socket-binding=mod-cluster-adv:add(\
multicast-address=${MOD_CLUSTER_MULTICAST_ADDRESS}, multicast-port=${MOD_CLUSTER_MULTICAST_PORT},\interface=public) && \
# Create mod_cluster proxy filter
${JBOSS_HOME}/bin/jboss-cli.sh --connect --commands=/subsystem=undertow/configuration=filter/mod-cluster=modcluster:add(\
advertise-socket-binding=mod-cluster-adv,management-socket-binding=http) && \
# Add that filter to the server
${JBOSS_HOME}/bin/jboss-cli.sh --connect --commands=/subsystem=undertow/server=default-server/host=default-host/filter-ref=modcluster:add() && \
# That's all we do here. The rest of the configuration is runtime dependent and it is done in balancer.sh
${JBOSS_HOME}/bin/jboss-cli.sh --connect --commands=:shutdown

RUN mkdir -p /opt/balancer/wildfly/standalone/log/
ADD balancer.sh /opt/balancer/
CMD ["/opt/balancer/balancer.sh"]

