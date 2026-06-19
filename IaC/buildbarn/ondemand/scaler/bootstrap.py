"""
Cloud-init user-data renderer for scaler-spawned workers.

The manual spawn tool (scripts/spawn-worker.sh) uses a minimal cloud-init
template + rsync-after-SSH to deliver the worker docker-compose stack. The
scaler can't SSH into freshly-created VMs from inside a container without
baking in SSH keys and dealing with known_hosts churn on recycled IPs. So
instead we produce a SELF-CONTAINED cloud-init that:

  1. Installs Docker (via the shared `get.docker.com` oneliner).
  2. Writes every worker/ config file into /opt/buildbarn/ using cloud-init's
     `write_files` section.
  3. Runs `docker compose up -d` as the final runcmd step.

The single source of truth for the worker/ tree lives in the repo. The scaler
mounts it RO at $WORKER_SRC (set in the Dockerfile) and reads each file here.
Placeholders (`__CENTRAL_PRIVATE_IP__`, etc.) are resolved against per-spawn
parameters — see render_user_data() below.

Cloud-init user-data size on Hetzner is 32 KB max. Our full tree is ~10 KB,
so we ship it uncompressed. If we ever exceed that, switch to the gzip+base64
encoding pattern documented at
https://cloudinit.readthedocs.io/en/latest/topics/format.html#user-data-script.
"""
from __future__ import annotations

import logging
import os
import re
from pathlib import Path
from textwrap import indent

log = logging.getLogger(__name__)

# Placeholder tokens shared with spawn-worker.sh. Keep this list in lockstep
# with the sed invocations in scripts/spawn-worker.sh:render() — a divergence
# means manual and automatic spawns ship different configs.
#
# __CONTAINER_IMAGE__ and __BAZEL_POOL_VALUE__ are the routing keys for
# scheduler platform queue matching (see worker.jsonnet header). If either
# is wrong the worker registers into a queue no client writes to, actions
# hang until `platformQueueWithNoWorkersTimeout` drops them — that's the
# silent-failure shape we hit before these placeholders existed, so
# bootstrap refuses to render if a pool doesn't supply them.
_PLACEHOLDERS = [
    "__CENTRAL_PRIVATE_IP__",
    "__CENTRAL_PUBLIC_URL__",
    "__POOL_NAME__",
    "__WORKER_HOSTNAME__",
    "__RUNNER_IMAGE__",
    "__BAZEL_POOL_VALUE__",
    "__CONTAINER_IMAGE__",
]

_PLACEHOLDER_RE = re.compile(r"__[A-Z_]+__")


def _substitute(content: str, subs: dict[str, str]) -> str:
    """Replace __FOO__ tokens. Raise if any unknown placeholder survives —
    that would ship broken configs to a live VM and waste a cpx42 minute."""
    for token, value in subs.items():
        content = content.replace(token, value)
    leftover = _PLACEHOLDER_RE.findall(content)
    if leftover:
        raise ValueError(
            f"unresolved placeholders in rendered content: {sorted(set(leftover))}"
        )
    return content


def _read_worker_file(worker_src: Path, rel_path: str, subs: dict[str, str]) -> str:
    """Load and substitute a file from the worker/ tree."""
    p = worker_src / rel_path
    content = p.read_text()
    return _substitute(content, subs)


def render_user_data(
    *,
    worker_src: Path,
    worker_hostname: str,
    central_private_ip: str,
    central_public_url: str,
    pool_name: str,
    runner_image: str,
    bazel_pool_value: str,
    container_image: str,
) -> str:
    """
    Produce a #cloud-config document as a string, ready to pass straight into
    hcloud_client.servers.create(user_data=...).

    The output layout:

        #cloud-config
        fqdn: ...
        packages: [...]
        write_files:
          - path: /opt/buildbarn/docker-compose.yml
            content: |
              <rendered compose>
          - path: /opt/buildbarn/config/common.libsonnet
            content: |
              <rendered common.libsonnet>
          ... same for worker.jsonnet, runner.jsonnet ...
        runcmd:
          - ... docker install, sysctl, swap ...
          - cd /opt/buildbarn && docker compose up -d
    """
    # Empty container_image would render `container-image: ''` into the
    # worker's platform tuple — registers into a queue no client writes to,
    # and Bazel's first action against this pool eventually times out with
    # DEADLINE_EXCEEDED. Refuse loudly so the failure surfaces here, where
    # the caller can attribute it to a misconfigured pool, rather than
    # 4 minutes later in a silent VM.
    if not container_image:
        raise ValueError(
            f"pool '{pool_name}' has empty container_image — cannot render "
            f"worker config (would register into an unmatched platform queue)"
        )
    if not runner_image:
        raise ValueError(
            f"pool '{pool_name}' has empty runner_image — cannot render "
            f"worker config (docker compose has nothing to pull)"
        )
    if not bazel_pool_value:
        raise ValueError(
            f"pool '{pool_name}' has no bazel_pool_value — cannot render "
            f"worker config (would register with Pool='' which matches nothing)"
        )

    subs = {
        "__CENTRAL_PRIVATE_IP__": central_private_ip,
        "__CENTRAL_PUBLIC_URL__": central_public_url,
        "__POOL_NAME__": pool_name,
        "__WORKER_HOSTNAME__": worker_hostname,
        "__RUNNER_IMAGE__": runner_image,
        "__BAZEL_POOL_VALUE__": bazel_pool_value,
        "__CONTAINER_IMAGE__": container_image,
    }

    # Render each file upfront so we bail on a missing/bad placeholder BEFORE
    # we start composing the cloud-init YAML (and certainly before calling
    # the Hetzner API).
    compose_yml = _read_worker_file(worker_src, "docker-compose.yml", subs)
    common_libs = _read_worker_file(worker_src, "config/common.libsonnet", subs)
    worker_js   = _read_worker_file(worker_src, "config/worker.jsonnet", subs)
    runner_js   = _read_worker_file(worker_src, "config/runner.jsonnet", subs)

    # The shell snippets here mirror worker/cloud-init.yml.tmpl's runcmd
    # block — kept in sync manually because there's no clean way to template
    # a cloud-init out of another cloud-init. See Phase 3 TODO: merge the
    # two code paths once the autoscale loop is trusted.
    bootstrap_yaml = f"""#cloud-config
# Rendered by scaler/bootstrap.py:render_user_data for a single spawn.
# DO NOT edit the VM in-place — re-spawn with fresh cloud-init instead.

fqdn: {worker_hostname}
hostname: {worker_hostname}

# Disable Hetzner's regional mirror BEFORE any apt module runs. mirror.hetzner.com
# periodically serves mid-sync indexes — 404 / "File has unexpected size ...
# Mirror sync in progress?" on trixie-backports — which fails `apt update`,
# fails the get.docker.com installer's own apt-get update, and leaves the VM a
# non-registering zombie the scaler can't distinguish from a healthy worker.
# The stock Hetzner Debian 13 image already ships deb.debian.org (globally
# load-balanced, never desynced in any incident we've seen) in debian.sources,
# so we simply disable the Hetzner drop-ins rather than rewrite them — rewriting
# their URL to deb.debian.org duplicates debian.sources and floods apt with
# "configured multiple times" warnings. Guard on debian.sources so we never
# strip the box of all sources. bootcmd runs in the init stage (before
# package_update / packages / runcmd) on every boot; idempotent (renamed files
# no longer match the *.sources / *.list globs).
bootcmd:
  - |
    set -e
    if [ -s /etc/apt/sources.list.d/debian.sources ]; then
      for f in /etc/apt/sources.list.d/*hetzner*.sources /etc/apt/sources.list.d/*hetzner*.list; do
        [ -e "$f" ] || continue
        mv -f "$f" "$f.disabled"
      done
    fi

package_update: true
package_upgrade: false
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - jq
  - lsb-release

write_files:
  - path: /etc/cloud/cloud.cfg.d/99-disable-manage-resolv-conf.cfg
    permissions: '0644'
    content: |
      manage_resolv_conf: false

  - path: /opt/buildbarn/docker-compose.yml
    permissions: '0644'
    content: |
{indent(compose_yml, "      ")}

  - path: /opt/buildbarn/config/common.libsonnet
    permissions: '0644'
    content: |
{indent(common_libs, "      ")}

  - path: /opt/buildbarn/config/worker.jsonnet
    permissions: '0644'
    content: |
{indent(worker_js, "      ")}

  - path: /opt/buildbarn/config/runner.jsonnet
    permissions: '0644'
    content: |
{indent(runner_js, "      ")}

runcmd:
  # DNS pinning + /etc/hosts entry, matching the Jenkins htz.cloud.groovy
  # 'deb-docker' init.
  - |
    cat > /etc/resolv.conf <<EOF
    nameserver 9.9.9.9
    nameserver 1.1.1.1
    EOF
  - sh -c 'grep -q repo.ci.percona.com /etc/hosts || echo "10.30.6.9 repo.ci.percona.com" >> /etc/hosts'

  # Swap file — for memory spikes during linker runs.
  - |
    if ! swapon --show | grep -q /swapfile; then
      fallocate -l 32G /swapfile
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi

  # Kernel tuning for many concurrent file descriptors / network connections.
  - sysctl -w net.ipv4.tcp_fin_timeout=15
  - sysctl -w net.ipv6.conf.all.disable_ipv6=1
  - sysctl -w net.ipv6.conf.default.disable_ipv6=1
  - sysctl -w fs.inotify.max_user_watches=10000000
  - sysctl -w fs.aio-max-nr=1048576
  - sysctl -w fs.file-max=6815744

  # Docker install + stack bring-up, fail-closed. Each runcmd entry runs
  # independently and a failure does NOT abort the rest, so historically a
  # broken docker install still fell through to `touch .ready` and advertised
  # a dead worker. Wrap the whole critical path in one POSIX-sh block that
  # only touches the readiness sentinel after a container is confirmed
  # running; on any failure it drops a .failed sentinel instead. (POSIX sh —
  # no `pipefail` — so we download-then-exec the docker script rather than
  # piping curl into sh, otherwise a curl failure would be masked by sh's
  # exit code.)
  - |
    set -e
    fail() {{ echo "bb-worker bootstrap FAILED: $1" >&2; touch /run/bb-worker.failed; exit 1; }}

    # get.docker.com runs its own `apt-get update`, which can still catch a
    # transient hiccup even with deb.debian.org pinned — retry a few times.
    ok=0
    for attempt in 1 2 3; do
      if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh; then
        ok=1; break
      fi
      echo "docker install attempt $attempt failed; retry in 15s" >&2
      sleep 15
    done
    [ "$ok" = 1 ] || fail "docker install failed after 3 attempts"

    systemctl enable --now docker || fail "could not enable docker.service"

    # Runtime dirs that bb-worker / runner-installer won't auto-create.
    mkdir -p /opt/buildbarn/volumes/worker/build /opt/buildbarn/volumes/worker/cache /opt/buildbarn/volumes/bb

    # Bring the stack up. No `pull` step — `up` pulls what's missing, which is
    # faster on a fresh VM (all three images are absent).
    cd /opt/buildbarn
    docker compose up -d || fail "docker compose up failed"

    # `up -d` exits 0 even when a container immediately crash-loops or exits,
    # so verify at least one container is actually running before signalling
    # ready. This is what keeps the scaler from counting a dead VM as capacity.
    sleep 5
    [ -n "$(docker compose ps -q 2>/dev/null)" ] || {{ docker compose ps >&2 || true; fail "no running container after 'compose up -d'"; }}

    # Sentinel for the scaler (or an operator) to verify cloud-init reached the
    # end successfully — we use this instead of `cloud-init status --wait`
    # because a failure inside runcmd still produces status=done.
    touch /run/bb-worker.ready

final_message: "bb-psmdb-worker (scaler-spawned) cloud-init done in $UPTIME s"
"""

    # Guard: Hetzner hard-rejects >32 KB. Warn well before, because labels +
    # metadata also count and we want headroom for future config growth.
    size = len(bootstrap_yaml.encode("utf-8"))
    if size > 24 * 1024:
        log.warning(
            "rendered cloud-init is %d bytes (close to Hetzner's 32 KB limit); "
            "consider trimming comments or compressing.", size,
        )
    elif size > 32 * 1024:
        raise ValueError(
            f"rendered cloud-init is {size} bytes — exceeds Hetzner's 32 KB limit. "
            "Either trim content or switch to gzip+base64 encoding."
        )

    return bootstrap_yaml


# ---------------------------------------------------------------------------
# Module self-check — a `python -m scaler.bootstrap` (or `python bootstrap.py`
# with $WORKER_SRC set) renders a sample user-data to stdout and exits. Very
# useful when debugging placeholder substitution before we touch hcloud.
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import sys

    src = Path(os.environ.get("WORKER_SRC", "/worker"))
    if not src.exists():
        print(f"WORKER_SRC={src} does not exist", file=sys.stderr)
        sys.exit(1)

    sample_runner = (
        "ghcr.io/vorsel/psmdb-buildbarn-runners/ubuntu-noble-x86_64:"
        "8.3-9873907c9659eb73f84e6d63571bca6667861f80"
    )
    rendered = render_user_data(
        worker_src=src,
        worker_hostname="bb-worker-dryrun-00000000-000000",
        central_private_ip="10.0.0.1",
        central_public_url="http://CENTRAL_PUB:7984",
        pool_name="ubuntu-noble-x86_64__v8_3__9873907c9659",
        runner_image=sample_runner,
        bazel_pool_value="x86_64",
        container_image=f"docker://{sample_runner}",
    )
    print(rendered)
