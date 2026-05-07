# PSMDB BuildBarn runner image — Debian Bookworm 12, aarch64
#
# Covers Jenkins stage 'Debian Bookworm(12)(aarch64)' which invokes
# buildStage("debian:bookworm", "--build_deb=1") on a docker-aarch64 agent.
# Built under `docker buildx build --platform=linux/arm64`; FROM debian:bookworm
# resolves to the arm64 manifest entry at build time.
#
# Mirror of debian-bookworm-x86_64/Dockerfile — body is byte-for-byte
# identical, only the LABEL metadata differs (arch / title / description).
#
# KNOWN FAILURE POINT (expected, used to drive the next fix):
#   install_deps() in psmdb_builder.sh (around line 471) does:
#       add-apt-repository -y ppa:deadsnakes/ppa
#       apt install -y python3.13 python3.13-venv python3.13-dev
#   Debian has no PPA system, so this line will fail. The failure is the
#   signal to decide how to provide Python 3.13 on Debian:
#     - build from source in install_deps() (slow, fat image)
#     - use deb.debian.org backports or a third-party apt source
#     - use pyenv / uv / rye (adds an extra tool)
#     - test whether stock Debian python3 (3.11) is sufficient for the
#       PSMDB build; if yes, gate the 3.13 install behind an Ubuntu check
#
# Once the Python-3.13 question is answered, patch runners/psmdb_builder.sh
# with per-distro branching and rebuild. Until then, this image build is
# expected to FAIL — same as the x86_64 sibling.

FROM debian:bookworm

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

LABEL org.opencontainers.image.title="psmdb-runner-debian-bookworm-aarch64"
LABEL org.opencontainers.image.description="BuildBarn runner built from psmdb_builder.sh install_deps() on Debian Bookworm 12 aarch64"
LABEL org.percona.psmdb.os="debian-bookworm"
LABEL org.percona.psmdb.glibc="2.36"
LABEL org.percona.psmdb.arch="aarch64"
LABEL org.percona.psmdb.version=$PSMDB_VERSION
LABEL org.percona.psmdb.builder_script="percona-packaging/scripts/psmdb_builder.sh install_deps()"
