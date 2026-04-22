# PSMDB BuildBarn runner image — Oracle Linux 9, x86_64
#
# Covers Jenkins stages that invoke buildStage("oraclelinux:9", ...):
#   - build_rpm        (OL9 rpm)
#   - build_tarball    (OL9 binary tarball, glibc 2.34)
# psmdb_builder.sh install_deps() on OL9 uses the rhel9 branch (enables CRB,
# installs gcc-toolset-13 / devtoolset equivalents, etc).

FROM oraclelinux:9

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
ARG PSMDB_VERSION=8.3
ARG PSMDB_BUILDER_SCRIPT_PATH=IaC/buildbarn/runners/psmdb_builder_8_3.sh

ARG CACHE_BUST=0
RUN mkdir -p /tmp/build \
 && RAW_URL="$(echo ${JENKINS_PIPELINES_REPO} | sed -re 's|github.com|raw.githubusercontent.com|; s|\.git$||')/${JENKINS_PIPELINES_BRANCH}/${PSMDB_BUILDER_SCRIPT_PATH}" \
 && echo "CACHE_BUST=${CACHE_BUST} fetching ${RAW_URL}" \
 && wget -q "${RAW_URL}" -O /tmp/psmdb_builder.sh \
 && chmod +x /tmp/psmdb_builder.sh \
 && bash -x /tmp/psmdb_builder.sh --builddir=/tmp/build --install_deps=1 \
 && rm -rf /tmp/psmdb_builder.sh /tmp/build /root/.cache /var/cache/dnf

LABEL org.opencontainers.image.title="psmdb-runner-oraclelinux-9-x86_64"
LABEL org.opencontainers.image.description="BuildBarn runner built from psmdb_builder.sh install_deps() on Oracle Linux 9 x86_64"
LABEL org.percona.psmdb.os="oraclelinux-9"
LABEL org.percona.psmdb.glibc="2.34"
LABEL org.percona.psmdb.arch="x86_64"
LABEL org.percona.psmdb.version=$PSMDB_VERSION
LABEL org.percona.psmdb.builder_script="${PSMDB_BUILDER_SCRIPT_PATH} install_deps()"
