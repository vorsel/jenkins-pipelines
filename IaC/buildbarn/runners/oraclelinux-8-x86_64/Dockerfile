# PSMDB BuildBarn runner image — Oracle Linux 8, x86_64
#
# Covers the hottest set of Jenkins stages in percona-server-for-mongodb-8.3.groovy:
#   - get_sources        (source tarball)
#   - build_src_rpm      (generic source rpm)
#   - build_rpm          (OL8 rpm)
#   - build_tarball      (OL8 binary tarball, glibc 2.28)
# All four invoke buildStage("oraclelinux:8", ...).
#
# psmdb_builder.sh install_deps() on RHEL/OL detects the family via
# /etc/redhat-release and /etc/os-release ID_LIKE; OL8 follows the rhel8 path
# (enables powertools/epel, installs devtoolset-12 / gcc-toolset-12, etc).

FROM oraclelinux:8

ENV LANG=C.UTF-8
ENV TZ=Etc/UTC

RUN dnf install -y --setopt=install_weak_deps=False \
        bash \
        ca-certificates \
        wget \
    && dnf clean all \
    && rm -rf /var/cache/dnf

ARG JENKINS_PIPELINES_REPO=https://github.com/vorsel/jenkins-pipelines.git
ARG JENKINS_PIPELINES_BRANCH=PSMDB-2034_buildbarn_setup
ARG PSMDB_BUILDER_SCRIPT_PATH=IaC/buildbarn/runners/psmdb_builder.sh

ARG CACHE_BUST=0
RUN mkdir -p /tmp/build \
 && RAW_URL="$(echo ${JENKINS_PIPELINES_REPO} | sed -re 's|github.com|raw.githubusercontent.com|; s|\.git$||')/${JENKINS_PIPELINES_BRANCH}/${PSMDB_BUILDER_SCRIPT_PATH}" \
 && echo "CACHE_BUST=${CACHE_BUST} fetching ${RAW_URL}" \
 && wget -q "${RAW_URL}" -O /tmp/psmdb_builder.sh \
 && chmod +x /tmp/psmdb_builder.sh \
 && bash -x /tmp/psmdb_builder.sh --builddir=/tmp/build --install_deps=1 \
 && rm -rf /tmp/psmdb_builder.sh /tmp/build /root/.cache /var/cache/dnf

LABEL org.opencontainers.image.title="psmdb-runner-oraclelinux-8-x86_64"
LABEL org.opencontainers.image.description="BuildBarn runner built from psmdb_builder.sh install_deps() on Oracle Linux 8 x86_64"
LABEL org.percona.psmdb.os="oraclelinux-8"
LABEL org.percona.psmdb.glibc="2.28"
LABEL org.percona.psmdb.arch="x86_64"
LABEL org.percona.psmdb.builder_script="IaC/buildbarn/runners/psmdb_builder.sh install_deps()"
