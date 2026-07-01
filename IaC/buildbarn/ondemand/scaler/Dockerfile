# bb-psmdb-ondemand scaler daemon image.
#
# Small Python 3.12 runtime plus grpcurl. We deliberately DON'T compile the
# BuildQueueState protobufs into Python — grpcurl consumes them via the
# scheduler's gRPC server reflection (which bb-scheduler enables by default),
# and shelling out keeps the Dockerfile short and avoids brittle proto
# pinning across bb-scheduler releases.

FROM python:3.12-slim-bookworm

# grpcurl from GitHub releases. Pin the version — bumping later is an explicit
# operator decision. Released binaries are musl-linked static builds so
# slim-bookworm works.
ARG GRPCURL_VERSION=1.9.1
RUN set -eux; \
    arch=$(dpkg --print-architecture); \
    case "$arch" in \
      amd64) grpcurl_arch=x86_64 ;; \
      arm64) grpcurl_arch=arm64  ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    curl -fsSL -o /tmp/grpcurl.tgz \
      "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_${grpcurl_arch}.tar.gz"; \
    tar -xzf /tmp/grpcurl.tgz -C /usr/local/bin grpcurl; \
    rm -f /tmp/grpcurl.tgz; \
    apt-get purge -y --auto-remove curl; \
    rm -rf /var/lib/apt/lists/*; \
    grpcurl --version

# wireguard-tools provides the `wg` CLI the scaler uses to add/remove AWS-worker
# peers on the host's wg0 (the container runs network_mode: host + cap NET_ADMIN,
# so `wg set wg0 …` operates on the host interface). Only needed when AWS
# fallback is enabled, but cheap enough to always include.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends wireguard-tools; \
    rm -rf /var/lib/apt/lists/*; \
    wg --version

WORKDIR /app

COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

COPY scaler.py bootstrap.py providers.py wireguard.py /app/

# Runtime knobs — all overridable via the compose environment:.
# POOLS_CONFIG points at the YAML mounted from compose/config/.
# WORKER_SRC points at the /worker tree mounted RO so the scaler can
# render cloud-init with the same source of truth spawn-worker.sh uses.
ENV POOLS_CONFIG=/config/ondemand-pools.yaml \
    WORKER_SRC=/worker \
    SCALER_DRY_RUN=true \
    PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "/app/scaler.py"]
