# PSMDB BuildBarn runner image — Debian Trixie 13, x86_64
#
# Smoke-test target for PSMDB-2028 (Debian 13 / Trixie support).
#
# Mirror of debian-bookworm-x86_64/Dockerfile — only the FROM line and the
# distro/glibc labels differ. Trixie ships Python 3.13 by default in the
# standard apt repos, so the deadsnakes-PPA detour that was needed on older
# Debians/Ubuntus does not apply here — psmdb_builder.sh's existing apt
# branch installs `python3*` from distro repos and that is enough.

FROM debian:trixie

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

LABEL org.opencontainers.image.title="psmdb-runner-debian-trixie-x86_64"
LABEL org.opencontainers.image.description="BuildBarn runner built from psmdb_builder.sh install_deps() on Debian Trixie 13 x86_64"
LABEL org.percona.psmdb.os="debian-trixie"
LABEL org.percona.psmdb.glibc="2.41"
LABEL org.percona.psmdb.arch="x86_64"
LABEL org.percona.psmdb.version=$PSMDB_VERSION
LABEL org.percona.psmdb.builder_script="percona-packaging/scripts/psmdb_builder.sh install_deps()"
