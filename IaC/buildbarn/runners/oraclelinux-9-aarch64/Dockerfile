# PSMDB BuildBarn runner image — Oracle Linux 9, aarch64
#
# Covers Jenkins stage 'Oracle Linux 9(aarch64)' which invokes
# buildStage("oraclelinux:9", "--build_rpm=1") on a docker-aarch64 agent.

FROM oraclelinux:9

ENV LANG=C.UTF-8
ENV TZ=Etc/UTC

RUN dnf install -y --setopt=install_weak_deps=False \
        bash \
        ca-certificates \
        wget \
    && dnf clean all \
    && rm -rf /var/cache/dnf

ARG MONGO_REPO=https://github.com/vorsel/percona-server-mongodb.git
ARG MONGO_BRANCH=master
ARG PSMDB_VERSION

ARG CACHE_BUST=0
RUN mkdir -p /tmp/build \
 && RAW_URL="$(echo ${MONGO_REPO} | sed -re 's|github.com|raw.githubusercontent.com|; s|\.git$||')/${MONGO_BRANCH}/percona-packaging/scripts/psmdb_builder.sh" \
 && echo "CACHE_BUST=${CACHE_BUST} fetching ${RAW_URL}" \
 && wget -q "${RAW_URL}" -O /tmp/psmdb_builder.sh \
 && chmod +x /tmp/psmdb_builder.sh \
 && bash -x /tmp/psmdb_builder.sh --builddir=/tmp/build --install_deps=1 \
 && rm -rf /tmp/psmdb_builder.sh /tmp/build /root/.cache /var/cache/dnf

LABEL org.opencontainers.image.title="psmdb-runner-oraclelinux-9-aarch64"
LABEL org.opencontainers.image.description="BuildBarn runner built from psmdb_builder.sh install_deps() on Oracle Linux 9 aarch64"
LABEL org.percona.psmdb.os="oraclelinux-9"
LABEL org.percona.psmdb.glibc="2.34"
LABEL org.percona.psmdb.arch="aarch64"
LABEL org.percona.psmdb.version=$PSMDB_VERSION
LABEL org.percona.psmdb.builder_script="percona-packaging/scripts/psmdb_builder.sh install_deps()"
