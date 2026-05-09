# PSMDB BuildBarn runner image — Oracle Linux 10, x86_64
#
# Smoke-test target for PSMDB-1943 (Oracle Linux 10 support).
#
# Mirror of oraclelinux-9-x86_64/Dockerfile — only the FROM line and the
# arch/glibc labels differ. install_deps() in psmdb_builder.sh needs a new
# `elif x"$RHEL" = x10` branch (additive — see PSMDB-1943); without it the
# image build will error during the install_deps step. That failure is the
# expected signal to land the corresponding psmdb_builder.sh patch.

FROM oraclelinux:10

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

LABEL org.opencontainers.image.title="psmdb-runner-oraclelinux-10-x86_64"
LABEL org.opencontainers.image.description="BuildBarn runner built from psmdb_builder.sh install_deps() on Oracle Linux 10 x86_64"
LABEL org.percona.psmdb.os="oraclelinux-10"
LABEL org.percona.psmdb.glibc="2.39"
LABEL org.percona.psmdb.arch="x86_64"
LABEL org.percona.psmdb.version=$PSMDB_VERSION
LABEL org.percona.psmdb.builder_script="percona-packaging/scripts/psmdb_builder.sh install_deps()"
