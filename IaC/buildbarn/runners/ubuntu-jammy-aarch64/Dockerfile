# PSMDB BuildBarn runner image — Ubuntu Jammy 22.04, aarch64
#
# Covers Jenkins stage 'Ubuntu Jammy(22.04)(aarch64)' which invokes
# buildStage("ubuntu:jammy", "--build_deb=1") on a docker-aarch64 agent.
# Built under `docker buildx build --platform=linux/arm64`; FROM ubuntu:22.04
# resolves to the arm64 manifest entry at build time.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        wget \
    && rm -rf /var/lib/apt/lists/*

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
 && rm -rf /tmp/psmdb_builder.sh /tmp/build /root/.cache /var/lib/apt/lists/*

LABEL org.opencontainers.image.title="psmdb-runner-ubuntu-jammy-aarch64"
LABEL org.opencontainers.image.description="BuildBarn runner built from psmdb_builder.sh install_deps() on Ubuntu Jammy 22.04 aarch64"
LABEL org.percona.psmdb.os="ubuntu-jammy"
LABEL org.percona.psmdb.glibc="2.35"
LABEL org.percona.psmdb.arch="aarch64"
LABEL org.percona.psmdb.version=$PSMDB_VERSION
LABEL org.percona.psmdb.builder_script="percona-packaging/scripts/psmdb_builder.sh install_deps()"
