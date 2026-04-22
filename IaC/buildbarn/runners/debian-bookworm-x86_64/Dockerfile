# PSMDB BuildBarn runner image — Debian Bookworm 12, x86_64
#
# Clone of the ubuntu-noble-x86_64/Dockerfile, only the base image changes.
# Everything else (psmdb_builder.sh install_deps(), fetching strategy,
# labels, CMD/ENTRYPOINT policy) is identical by design — the whole point
# of this variant matrix is "one Dockerfile pattern × N base images".
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
# expected to FAIL — that failure is the deliverable of this step.

FROM debian:bookworm

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

LABEL org.opencontainers.image.title="psmdb-runner-debian-bookworm-x86_64"
LABEL org.opencontainers.image.description="BuildBarn runner built from psmdb_builder.sh install_deps() on Debian Bookworm 12 x86_64"
LABEL org.percona.psmdb.os="debian-bookworm"
LABEL org.percona.psmdb.glibc="2.36"
LABEL org.percona.psmdb.arch="x86_64"
LABEL org.percona.psmdb.version=$PSMDB_VERSION
LABEL org.percona.psmdb.builder_script="${PSMDB_BUILDER_SCRIPT_PATH} install_deps()"
