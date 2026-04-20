# PSMDB BuildBarn runner image — Ubuntu Noble 24.04, x86_64
#
# Fetches the BuildBarn-tuned copy of psmdb_builder.sh from this repo
#   IaC/buildbarn/runners/psmdb_builder.sh
# and runs it with --install_deps=1. This mirrors the pattern used by
# buildStage() in psmdb/jenkins/percona-server-for-mongodb-8.3.groovy:
#       bash -x ./psmdb_builder.sh --builddir=${build_dir}/test --install_deps=1
#
# The script is fetched via wget (not COPY) because images are built
# remotely on BuildBarn worker nodes where the local IaC/ checkout is
# not available as a Docker build context. While we iterate on the
# script the fetched copy will eventually be upstreamed back into
# percona-server-mongodb/percona-packaging/scripts/.
#
# Every downstream phase inside psmdb_builder.sh (build_tarball /
# build_srpm / build_rpm / build_deb / build_source_deb) has an
# internal `if [ $FLAG = 0 ] return` guard and all flags default to 0,
# so only install_deps runs.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Minimum packages to fetch and execute psmdb_builder.sh; everything
# else is installed by install_deps() itself.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        wget \
    && rm -rf /var/lib/apt/lists/*

ARG JENKINS_PIPELINES_REPO=https://github.com/vorsel/jenkins-pipelines.git
ARG JENKINS_PIPELINES_BRANCH=PSMDB-2034_buildbarn_setup
ARG PSMDB_BUILDER_SCRIPT_PATH=IaC/buildbarn/runners/psmdb_builder.sh

# Fetch psmdb_builder.sh from the current branch of the IaC repo and
# run it with --install_deps=1. CACHE_BUST forces wget re-run on every
# `docker build --build-arg CACHE_BUST=$(date +%s)` so we always pick
# up the latest commit of the script while experimenting.
ARG CACHE_BUST=0
RUN mkdir -p /tmp/build \
 && RAW_URL="$(echo ${JENKINS_PIPELINES_REPO} | sed -re 's|github.com|raw.githubusercontent.com|; s|\.git$||')/${JENKINS_PIPELINES_BRANCH}/${PSMDB_BUILDER_SCRIPT_PATH}" \
 && echo "CACHE_BUST=${CACHE_BUST} fetching ${RAW_URL}" \
 && wget -q "${RAW_URL}" -O /tmp/psmdb_builder.sh \
 && chmod +x /tmp/psmdb_builder.sh \
 && bash -x /tmp/psmdb_builder.sh --builddir=/tmp/build --install_deps=1 \
 && rm -rf /tmp/psmdb_builder.sh /tmp/build /root/.cache /var/lib/apt/lists/*

LABEL org.opencontainers.image.title="psmdb-runner-ubuntu-noble-x86_64"
LABEL org.opencontainers.image.description="BuildBarn runner built from psmdb_builder.sh install_deps() on Ubuntu Noble 24.04 x86_64"
LABEL org.percona.psmdb.os="ubuntu-noble"
LABEL org.percona.psmdb.glibc="2.39"
LABEL org.percona.psmdb.arch="x86_64"
LABEL org.percona.psmdb.builder_script="IaC/buildbarn/runners/psmdb_builder.sh install_deps()"

# No CMD / ENTRYPOINT: BuildBarn's docker-compose.yml overrides the command
# to run bb_runner after runner-installer drops the binary into /bb.
