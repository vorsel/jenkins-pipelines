# PSMDB BuildBarn runner image — Ubuntu Noble 24.04, aarch64
#
# Covers Jenkins stage 'Ubuntu Noble(24.04)(aarch64)' which invokes
# buildStage("ubuntu:noble", "--build_deb=1") on a docker-aarch64 agent.
# Built under `docker buildx build --platform=linux/arm64`; FROM ubuntu:24.04
# resolves to the arm64 manifest entry at build time.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        wget \
    && rm -rf /var/lib/apt/lists/*

ARG JENKINS_PIPELINES_REPO=https://github.com/vorsel/jenkins-pipelines.git
ARG JENKINS_PIPELINES_BRANCH=PSMDB-2034_buildbarn_setup
ARG PSMDB_VERSION=8.3
ARG PSMDB_BUILDER_SCRIPT_PATH=IaC/buildbarn/runners/psmdb_builder_8_3.sh

ARG CACHE_BUST=0
RUN mkdir -p /tmp/build \
 && RAW_URL="$(echo ${JENKINS_PIPELINES_REPO} | sed -re 's|github.com|raw.githubusercontent.com|; s|\.git$||')/${JENKINS_PIPELINES_BRANCH}/${PSMDB_BUILDER_SCRIPT_PATH}" \
 && echo "CACHE_BUST=${CACHE_BUST} fetching ${RAW_URL}" \
 && wget -q "${RAW_URL}" -O /tmp/psmdb_builder.sh \
 && chmod +x /tmp/psmdb_builder.sh \
 && bash -x /tmp/psmdb_builder.sh --builddir=/tmp/build --install_deps=1 \
 && rm -rf /tmp/psmdb_builder.sh /tmp/build /root/.cache /var/lib/apt/lists/*

LABEL org.opencontainers.image.title="psmdb-runner-ubuntu-noble-aarch64"
LABEL org.opencontainers.image.description="BuildBarn runner built from psmdb_builder.sh install_deps() on Ubuntu Noble 24.04 aarch64"
LABEL org.percona.psmdb.os="ubuntu-noble"
LABEL org.percona.psmdb.glibc="2.39"
LABEL org.percona.psmdb.arch="aarch64"
LABEL org.percona.psmdb.version=$PSMDB_VERSION
LABEL org.percona.psmdb.builder_script="${PSMDB_BUILDER_SCRIPT_PATH} install_deps()"
