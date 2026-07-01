#!/usr/bin/env python3
"""
bb-psmdb-ondemand scaler daemon.

Runs on the central node, in a container on the same compose network as the
rest of the control plane. Every POLL_INTERVAL seconds it:

  1. Asks the scheduler (via BuildQueueState gRPC on 127.0.0.1:8984) for
     the current list of platform queues — each queue reports its queued
     operations and active-worker count.
  2. Asks Hetzner for the current list of VMs it owns (labelled with
     `psmdb.managed-by=bb-ondemand-scaler`).
  3. For each pool in ondemand-pools.yaml, decides:
       scale_up   — (a) pool is below its `min_nodes` floor, OR
                    (b) queue has work and more capacity is needed
       scale_down — a managed VM has been idle (no queued/active work for
                    its pool) for more than scale_down_idle_seconds AND
                    deleting it would not take the pool below `min_nodes`
  4. Executes those decisions by calling hcloud, UNLESS SCALER_DRY_RUN=true
     (the default until the operator switches it off).

Design notes:

  * No external state — Hetzner server labels are the source of truth. A
    scaler restart rebuilds its view by listing labelled servers.
  * BuildQueueState is consumed by shelling out to grpcurl. The alternative
    (compiling buildbarn/bb-remote-execution protos into Python) is more
    robust but adds 150 lines of build wiring; grpcurl via reflection costs
    ~50 ms per call and survives schema changes in the protos.
  * Scale-up sizes the fleet from live queue pressure, with a `min_nodes`
    floor that keeps at least N workers warm for the pool regardless of
    queue state. This dodges Bazel's FAILED_PRECONDITION on empty platform
    queues, at the cost of one always-on VM per `min_nodes>0` pool:
        desired_vms = max(pool.min_nodes,
                          ceil((queued + executing) / pool.concurrency))
        desired_vms = min(desired_vms, pool.max_nodes, global_budget)
        to_spawn    = min(desired_vms - current_pool_vms, SPAWN_THROTTLE)
    SPAWN_THROTTLE=1 means at most one VM per tick per pool — cold-starts
    proceed serially, so capacity errors surface one at a time and a burst
    that evaporates during boot costs us 1 unnecessary VM, not N.
  * Scale-down never reaps below `min_nodes`. A pool with min_nodes=1 will
    always have one warm VM, even after 10 min of idle.

See buildbarn-ondemand-scaler.md §5.2–5.8 for the full design.
"""
from __future__ import annotations

import dataclasses
import json
import logging
import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

import wireguard
from bootstrap import render_aws_user_data, render_user_data
from providers import (
    AwsOps,
    CloudProvider,
    HetznerOps,
    LABEL_WG_IP,
    LABEL_WG_PUBKEY,
    ManagedVM,
    sanitize_pool_slug,
)
from wireguard import WireguardCfg

# ---------------------------------------------------------------------------
# Configuration — every knob overridable via environment. Compose sets the
# defaults; human operators override per-deployment in .env.
# ---------------------------------------------------------------------------
POOLS_CONFIG = Path(os.environ.get("POOLS_CONFIG", "/config/ondemand-pools.yaml"))
WORKER_SRC   = Path(os.environ.get("WORKER_SRC",   "/worker"))
DRY_RUN      = os.environ.get("SCALER_DRY_RUN", "true").lower() in ("1", "true", "yes")

HCLOUD_TOKEN = os.environ.get("HCLOUD_TOKEN", "").strip()

# The scheduler's BuildQueueState endpoint. We default to the localhost port
# mapped in compose/docker-compose.yml; overridable for debugging from the
# operator's laptop (with ssh tunnel).
SCHEDULER_STATE_GRPC = os.environ.get("SCHEDULER_STATE_GRPC", "127.0.0.1:8984")

# The BuildQueueState gRPC service fully-qualified name. From upstream:
# https://github.com/buildbarn/bb-remote-execution/blob/master/pkg/proto/buildqueuestate/buildqueuestate.proto
BQS_SERVICE = "buildbarn.buildqueuestate.BuildQueueState"

# Maximum number of VMs the scale-up path will spawn for a single pool in
# one iteration. Keep at 1 during the multi-VM rollout so cold-starts proceed
# serially and we observe each VM register before committing to the next one.
# Raise to `None` (or the pool's `max_nodes`) once we trust the cold-start
# pipeline and want faster warm-up under large release-matrix bursts.
SPAWN_THROTTLE_PER_POOL = int(os.environ.get("SPAWN_THROTTLE_PER_POOL", "1"))

# Label/tag conventions and the VM-name slug helper now live in providers.py
# (shared verbatim by both the Hetzner and AWS backends).
log = logging.getLogger("scaler")

# Default diversified Graviton spot pool for AWS fallback. Every type is
# 8 vCPU / >=32 GB RAM — at least as good as Hetzner cax31 (8c / 16 GB) on both
# axes, with faster Neoverse-V1/V2 cores than cax31's Neoverse-N1. Multiple
# families (m=32GB, r=64GB; -d variants add local NVMe that helps the
# hardlinking cache) and generations (6/7/8) give the spot allocator many
# capacity pools, so `no-capacity` and interruption pressure are spread out.
# The scaler tries them in order on InsufficientInstanceCapacity (same pattern
# as Hetzner's region_try_chain). Mirrors percona-cd-platform's proven
# jenkins-arm-fleet instance set.
DEFAULT_AWS_INSTANCE_TYPES = [
    "m7g.2xlarge", "m6g.2xlarge", "m8g.2xlarge", "m7gd.2xlarge",
    "m6gd.2xlarge", "r7g.2xlarge", "r6g.2xlarge", "r8g.2xlarge",
]


def _as_list(v) -> list[str]:
    """Normalize a YAML scalar-or-list into a list[str]. None/empty → []."""
    if v is None:
        return []
    if isinstance(v, str):
        return [v]
    return [str(x) for x in v]

# ---------------------------------------------------------------------------
# Typed config + domain objects.
# ---------------------------------------------------------------------------
@dataclasses.dataclass
class GlobalCfg:
    scheduler_state_grpc: str
    scheduler_public_url: str | None
    scheduler_private_ip: str | None
    ssh_key_ids: list[int]
    network_id: int
    os_image: str
    region_try_chain: list[str]
    max_total_nodes: int
    max_cost_per_hour_eur: float
    poll_interval_seconds: int
    scale_down_idle_seconds: int
    scale_up_threshold: int

    # --- AWS Graviton fallback (optional; enabled iff aws_enabled) ----------
    aws_enabled: bool = False
    aws_region: str = "eu-central-1"        # closest to hel1 → low CAS-over-wg latency
    aws_subnet_id: str = ""                 # subnet w/ egress (any VPC; wg needs only outbound)
    aws_security_group_ids: list[str] = dataclasses.field(default_factory=list)
    aws_ami_id: str = ""                    # Ubuntu arm64 AMI (resolve via SSM once, pin here)
    aws_key_name: str = ""                  # optional EC2 keypair for break-glass SSH
    aws_use_spot: bool = True               # spot by default (~70% cheaper); on-demand if False
    aws_billing_tag: str = "psmdb-worker"   # iit-billing-tag: cost attribution + cleanup Lambdas
    # Root EBS size (GB). The stock Ubuntu arm64 AMI ships an 8 GB root — far
    # too small for the 32 GB swapfile + ~100 GB hardlinking cache + runner
    # image. Override the AMI's default with a big gp3 root (deleted on
    # terminate). Hetzner cax31/cpx42 give 160/320 GB locally; match that here.
    aws_root_volume_gb: int = 200
    # Diversified Graviton spot pool (see DEFAULT_AWS_INSTANCE_TYPES). Tried in
    # order on InsufficientInstanceCapacity. Per-pool override via the pool's
    # `aws_instance_types`.
    aws_instance_types: list[str] = dataclasses.field(
        default_factory=lambda: list(DEFAULT_AWS_INSTANCE_TYPES))
    # When true, EVERY aarch64 pool (bazel_pool_value == "aarch64") is eligible
    # for AWS fallback on Hetzner exhaustion — no per-pool aws_fallback needed.
    # x86_64 pools are never affected (can't run x86 on Graviton). This is the
    # intended switch for "Hetzner ARM capacity is unobtainable": a full build
    # matrix routes to many distro-specific aarch64 pools, all of which must
    # fall back, not just a hand-picked few.
    aws_fallback_all_aarch64: bool = False

    # --- WireGuard hub (required when aws_enabled) --------------------------
    wg_iface: str = "wg0"
    wg_hub_pubkey: str = ""
    wg_hub_endpoint: str = ""               # "<public-ip-or-host>:51820"
    wg_cidr: str = "10.99.0.0/16"
    wg_hub_ip: str = "10.99.0.1"
    # CIDRs the worker routes through the tunnel. Defaults to the central's
    # private IP /32; extend with repo.ci.percona.com (10.30.6.9/32) if RBE
    # build actions need it. Filled at load time from scheduler_private_ip
    # when left blank.
    wg_allowed_ips: str = ""


@dataclasses.dataclass
class PoolCfg:
    name: str
    # runner_image is the SINGLE source of truth: full ghcr.io URL with
    # immutable `:<psmdb-version>-<git-sha>` tag, e.g.
    # `ghcr.io/vorsel/psmdb-buildbarn-runners/ubuntu-noble-x86_64:8.0-<sha>`.
    # Both the docker-compose `image:` field on the worker and the routing
    # key emitted by the Bazel client are derived from this. See
    # ondemand-pools.yaml header for the lifecycle (when to bump, when to
    # add new pool entries, how cross-release coexistence works).
    runner_image: str
    # bazel_pool_value is the architecture label Bazel stamps into the
    # `Pool` platform property (x86_64 / aarch64). It's part of the
    # routing-key tuple — wrong value → worker lands in an unused queue.
    bazel_pool_value: str
    # psmdb_version is informational ("8.0" / "8.3" / "master") — used for
    # the `psmdb.version` Hetzner label and for log readability. Routing
    # does NOT key off this field; it keys off container_image which
    # already encodes the version inside the immutable tag.
    psmdb_version: str
    server_type: str
    concurrency: int
    min_nodes: int
    max_nodes: int
    # Primary cloud for this pool. "hetzner" (default) spawns cax31/cpx42;
    # "aws" makes AWS the primary (not used today — kept for symmetry).
    provider: str = "hetzner"
    # Opt this pool into AWS Graviton fallback on Hetzner region exhaustion.
    # Only meaningful for aarch64 pools; x86_64 pools must NOT set this (they'd
    # try to run an x86 workload on arm64 Graviton).
    aws_fallback: bool = False
    # Optional per-pool override of the global aws.instance_types list. Empty →
    # inherit GlobalCfg.aws_instance_types.
    aws_instance_types: list[str] = dataclasses.field(default_factory=list)

    @property
    def container_image(self) -> str:
        """Routing key as it appears in the Bazel platform tuple and in
        the scheduler's predeclared queues. `docker://` prefix is part of
        the contract that PSMDB's psmdb_rbe_containers.bzl emits — strip
        or alter it and matching breaks silently."""
        return f"docker://{self.runner_image}"


@dataclasses.dataclass
class Cfg:
    global_: GlobalCfg
    pools: dict[str, PoolCfg]


@dataclasses.dataclass
class PlatformQueue:
    """One row from BuildQueueState.ListPlatformQueues, summed across the
    nested size-class queues that bb-scheduler exposes per platform."""
    instance_prefix: str
    platform_props: dict[str, str]
    queued: int               # sum of queuedOperationsCount values across size classes
    executing: int            # sum of executingWorkersCount — scheduler is actively dispatching
    idle: int                 # sum of idleWorkersCount — workers waiting for work
    workers_total: int        # sum of workersCount — every registered worker slot

    @property
    def container_image(self) -> str:
        """Full `docker://...` URL the scheduler stores for this queue's
        `container-image` exec property. Empty string if the property is
        missing (shouldn't happen in practice — every PSMDB-emitted
        platform tuple carries it)."""
        return self.platform_props.get("container-image", "")

    @property
    def has_workers(self) -> bool:
        """True iff there's at least one registered worker slot for this queue."""
        return self.workers_total > 0

    @property
    def is_busy(self) -> bool:
        """True iff there is *any* work in flight or queued.

        Used by the scale-down path: while busy, we never reap. queued+executing
        stays nonzero throughout an active build even when the scaler polls
        between dispatches (queued briefly hits 0 but executing won't)."""
        return self.queued > 0 or self.executing > 0


# ManagedVM lives in providers.py (shared by both backends).


# ---------------------------------------------------------------------------
# Config loading.
# ---------------------------------------------------------------------------
def load_config(path: Path) -> Cfg:
    raw = yaml.safe_load(path.read_text())
    g = raw["global"]
    pools: dict[str, PoolCfg] = {}
    for name, pc in raw.get("pools", {}).items():
        # `runner_image` is mandatory — there's no scaffolded-but-unprimed
        # state in the new model, every pool entry pins a real immutable
        # ghcr tag. Reject loudly so config typos surface at startup, not
        # 30 s later when the scaler tries to spawn against a malformed
        # pool definition.
        runner_image = pc.get("runner_image")
        if not runner_image:
            raise ValueError(
                f"pool '{name}' missing required `runner_image` (full ghcr URL "
                f"with immutable :<version>-<git-sha> tag — see ondemand-pools.yaml header)"
            )
        pools[name] = PoolCfg(
            name=name,
            runner_image=str(runner_image),
            bazel_pool_value=str(pc["bazel_pool_value"]),
            psmdb_version=str(pc["psmdb_version"]),
            server_type=pc["server_type"],
            concurrency=int(pc["concurrency"]),
            min_nodes=int(pc.get("min_nodes", 0)),
            max_nodes=int(pc["max_nodes"]),
            provider=str(pc.get("provider", "hetzner")),
            aws_fallback=bool(pc.get("aws_fallback", False)),
            aws_instance_types=_as_list(pc.get("aws_instance_types")),
        )

    # AWS + WireGuard config. The YAML `aws:` block carries non-secret shape
    # (region, subnet, SG, AMI, instance defaults); credentials come from the
    # boto3 default chain (AWS_ACCESS_KEY_ID/SECRET in the scaler env). The
    # WireGuard hub pubkey/endpoint default to env vars written by
    # scripts/setup-wireguard-hub.sh so they don't have to live in the YAML.
    aws = raw.get("aws", {}) or {}
    wg = raw.get("wireguard", {}) or {}
    aws_enabled = bool(aws.get("enabled", False))
    scheduler_private_ip = g.get("scheduler_private_ip")
    wg_allowed_ips = wg.get("allowed_ips") or os.environ.get("WG_ALLOWED_IPS", "")
    if not wg_allowed_ips and scheduler_private_ip:
        # Minimal default: route just the central's private IP through the
        # tunnel. Operators add 10.30.6.9/32 (repo.ci) here if builds need it.
        wg_allowed_ips = f"{scheduler_private_ip}/32"

    return Cfg(
        global_=GlobalCfg(
            scheduler_state_grpc=g.get("scheduler_state_grpc", SCHEDULER_STATE_GRPC),
            scheduler_public_url=g.get("scheduler_public_url"),
            scheduler_private_ip=scheduler_private_ip,
            ssh_key_ids=list(g["hcloud_ssh_key_ids"]),
            network_id=int(g["hcloud_network_id"]),
            os_image=g["hcloud_os_image"],
            region_try_chain=list(g["region_try_chain"]),
            max_total_nodes=int(g["max_total_nodes"]),
            max_cost_per_hour_eur=float(g["max_cost_per_hour_eur"]),
            poll_interval_seconds=int(g["poll_interval_seconds"]),
            scale_down_idle_seconds=int(g["scale_down_idle_seconds"]),
            scale_up_threshold=int(g["scale_up_threshold"]),
            aws_enabled=aws_enabled,
            aws_region=str(aws.get("region", "eu-central-1")),
            aws_subnet_id=str(aws.get("subnet_id") or os.environ.get("AWS_SUBNET_ID", "")),
            aws_security_group_ids=list(
                aws.get("security_group_ids")
                or ([s for s in os.environ.get("AWS_SECURITY_GROUP_IDS", "").split(",") if s])
            ),
            aws_ami_id=str(aws.get("ami_id") or os.environ.get("AWS_AMI_ID", "")),
            aws_key_name=str(aws.get("key_name") or os.environ.get("AWS_KEY_NAME", "")),
            aws_use_spot=bool(aws.get("use_spot", True)),
            aws_billing_tag=str(aws.get("billing_tag", "psmdb-worker")),
            aws_root_volume_gb=int(aws.get("root_volume_gb", 200)),
            aws_instance_types=(_as_list(aws.get("instance_types")) or list(DEFAULT_AWS_INSTANCE_TYPES)),
            aws_fallback_all_aarch64=bool(aws.get("fallback_all_aarch64", False)),
            wg_iface=str(wg.get("iface") or os.environ.get("WG_IFACE", "wg0")),
            wg_hub_pubkey=str(wg.get("hub_pubkey") or os.environ.get("WG_HUB_PUBKEY", "")),
            wg_hub_endpoint=str(wg.get("hub_endpoint") or os.environ.get("WG_HUB_ENDPOINT", "")),
            wg_cidr=str(wg.get("cidr", "10.99.0.0/16")),
            wg_hub_ip=str(wg.get("hub_ip", "10.99.0.1")),
            wg_allowed_ips=wg_allowed_ips,
        ),
        pools=pools,
    )


# ---------------------------------------------------------------------------
# BuildQueueState via grpcurl.
# ---------------------------------------------------------------------------
def grpcurl(endpoint: str, method: str, body: str = "{}") -> dict[str, Any]:
    """
    Call bb-scheduler's BuildQueueState via grpcurl reflection.

    Returns the parsed JSON response. Raises CalledProcessError with stderr
    included on persistent failure — the scaler caller should catch and log,
    never silently swallow, so schema drift shows up in operator logs.

    Transient failures (scheduler restarting during a redeploy, brief gRPC
    transport blip) are absorbed by a small retry-with-backoff: 3 attempts
    at 0.5s / 1.0s / 2.0s. This is deliberately narrow — we retry the WHOLE
    call with the same args, we don't inspect the error class, and we don't
    retry forever. A real outage (scheduler process dead, schema mismatch,
    network partition) still surfaces as an exception after ~3.5 s, which
    the outer loop in main() catches and logs via `log.exception`.

    Rationale for not classifying errors: grpcurl exits 1 for almost
    everything (transport error, server error, reflection failure, JSON
    decode failure). Parsing stderr to discriminate would be brittle and
    version-specific. A uniform short retry is simpler and correct: the
    transient cases heal, the persistent cases still fail fast enough.
    """
    cmd = [
        "grpcurl",
        "-plaintext",
        "-d", body,
        endpoint,
        f"{BQS_SERVICE}/{method}",
    ]
    delays = (0.5, 1.0, 2.0)
    last_err: subprocess.CalledProcessError | None = None
    for attempt, delay in enumerate(delays, start=1):
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            return json.loads(result.stdout or "{}")
        except subprocess.CalledProcessError as e:
            last_err = e
            if attempt == len(delays):
                break
            log.debug(
                "grpcurl %s attempt %d/%d failed: %s — retrying in %ss",
                method, attempt, len(delays),
                (e.stderr or "").strip()[:120], delay,
            )
            time.sleep(delay)
    assert last_err is not None
    raise last_err


def _sum_queued(qoc: Any) -> int:
    """
    `queuedOperationsCount` in bb-scheduler's JSON is a `map<string, uint32>`
    keyed by invocation id (sum of values = total queue depth for the size
    class). When empty, proto3 JSON encodes it as `{}`. Be defensive against
    schema drift: if a future bb-scheduler ships it as a plain integer, take
    that; if it's something we don't recognize, fall back to 0 with a debug
    log so the operator can tell why the scaler thinks the queue is empty.
    """
    if isinstance(qoc, dict):
        total = 0
        for v in qoc.values():
            try:
                total += int(v)
            except (TypeError, ValueError):
                continue
        return total
    if isinstance(qoc, (int, str)):
        try:
            return int(qoc)
        except (TypeError, ValueError):
            return 0
    return 0


def list_platform_queues(endpoint: str) -> list[PlatformQueue]:
    """
    Parse BuildQueueState.ListPlatformQueues into a flat list of pools.

    Real response shape (bb-scheduler 20260326-era):

        {
          "platformQueues": [
            {
              "name": {
                "instanceNamePrefix": "hardlinking",
                "platform": { "properties": [{"name":..., "value":...}, ...] }
              },
              "sizeClassQueues": [
                {
                  "workersCount": 12,
                  "rootInvocation": {
                    "queuedOperationsCount": {},        // map<invocation_id, uint32>
                    "executingWorkersCount": 11,
                    "idleWorkersCount": 1,
                    ...
                  }
                }
              ]
            }
          ]
        }

    A platform queue can have multiple size classes (small/medium/large
    runners on the same image). We sum counters across them so the scaler
    sees one consolidated "is the pool busy / does it have workers" signal
    per platform. PSMDB today has exactly one size class per pool, so the
    summing is a no-op — but the code is correct for the multi-class future.
    """
    resp = grpcurl(endpoint, "ListPlatformQueues")
    queues = []
    for entry in resp.get("platformQueues", []):
        name = entry.get("name", {})
        platform = name.get("platform", {})
        props: dict[str, str] = {}
        for p in platform.get("properties", []):
            props[p.get("name", "")] = p.get("value", "")

        queued = 0
        executing = 0
        idle = 0
        workers_total = 0
        for sc in entry.get("sizeClassQueues", []):
            workers_total += int(sc.get("workersCount", 0) or 0)
            inv = sc.get("rootInvocation", {}) or {}
            queued    += _sum_queued(inv.get("queuedOperationsCount", {}))
            executing += int(inv.get("executingWorkersCount", 0) or 0)
            idle      += int(inv.get("idleWorkersCount", 0) or 0)

        queues.append(PlatformQueue(
            instance_prefix=name.get("instanceNamePrefix", ""),
            platform_props=props,
            queued=queued,
            executing=executing,
            idle=idle,
            workers_total=workers_total,
        ))
    return queues


# HetznerOps / AwsOps live in providers.py.


# ---------------------------------------------------------------------------
# Main loop.
# ---------------------------------------------------------------------------
_stop = False


def _handle_signal(_signum, _frame):
    global _stop
    _stop = True
    log.info("stop requested — finishing current loop iteration and exiting")


def _match_pool(queues: list[PlatformQueue], pool: PoolCfg) -> PlatformQueue | None:
    """Match a pool to its scheduler queue by EXACT (container-image, Pool)
    tuple equality.

    The scheduler does byte-exact platform-tuple matching internally — we
    mirror that here so the scaler's view agrees with the scheduler's.
    Matching on container-image alone would be ambiguous if we ever added
    aarch64 pools that share an image (none today; cheap to be precise)."""
    target_image = pool.container_image
    target_pool = pool.bazel_pool_value
    for q in queues:
        if (q.container_image == target_image
                and q.platform_props.get("Pool", "") == target_pool):
            return q
    return None


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _effective_instance_types(pool: PoolCfg, cfg: Cfg) -> list[str]:
    """Per-pool AWS instance-type list if set, else the global default list."""
    return pool.aws_instance_types or cfg.global_.aws_instance_types


def _pool_aws_fallback_ok(
    pool: PoolCfg, cfg: Cfg, providers: dict[str, CloudProvider], wgcfg: WireguardCfg
) -> bool:
    """True iff this pool is eligible for AWS Graviton fallback: it opted in
    (per-pool `aws_fallback`, or the global `fallback_all_aarch64` for any
    aarch64 pool), has at least one candidate instance type, AWS is
    configured/enabled, and the WireGuard hub is up."""
    opted_in = pool.aws_fallback or (
        cfg.global_.aws_fallback_all_aarch64 and pool.bazel_pool_value == "aarch64"
    )
    return bool(
        opted_in
        and cfg.global_.aws_enabled
        and "aws" in providers
        and wgcfg.enabled
        and _effective_instance_types(pool, cfg)
    )


def _spawn_aws(
    cfg: Cfg, providers: dict[str, CloudProvider], wgcfg: WireguardCfg,
    pool: PoolCfg, hostname: str, suffix: str, used_wg_ips: set[str],
) -> bool:
    """Spawn one AWS Graviton worker: mint a WireGuard keypair, allocate a
    tunnel IP, register the peer on the hub, then RunInstances with the
    wg-enabled cloud-init. Catches its own errors (returns False) and tears
    the half-added peer back down so a failed spawn leaves no orphan."""
    pub: str | None = None
    try:
        priv, pub = wireguard.gen_keypair()
        tunnel_ip = wireguard.allocate_tunnel_ip(wgcfg.cidr, used_wg_ips, {wgcfg.hub_ip})
        wireguard.add_peer(wgcfg.iface, pub, tunnel_ip)
        user_data = render_aws_user_data(
            worker_src=WORKER_SRC,
            worker_hostname=hostname,
            central_private_ip=cfg.global_.scheduler_private_ip or "",
            central_public_url=cfg.global_.scheduler_public_url or "",
            pool_name=pool.name,
            runner_image=pool.runner_image,
            container_image=pool.container_image,
            bazel_pool_value=pool.bazel_pool_value,
            wg_private_key=priv,
            wg_tunnel_ip=tunnel_ip,
            wg_hub_pubkey=wgcfg.hub_pubkey,
            wg_hub_endpoint=wgcfg.hub_endpoint,
            wg_allowed_ips=wgcfg.allowed_ips,
        )
        providers["aws"].create_worker(
            pool=pool, global_=cfg.global_, user_data=user_data, name_suffix=suffix,
            extra_labels={LABEL_WG_PUBKEY: pub, LABEL_WG_IP: tunnel_ip},
            instance_types=_effective_instance_types(pool, cfg),
        )
        used_wg_ips.add(tunnel_ip)
        return True
    except Exception:  # noqa: BLE001
        log.exception("aws spawn failed for pool=%s — rolling back wg peer", pool.name)
        if pub:
            try:
                wireguard.remove_peer(wgcfg.iface, pub)
            except Exception:  # noqa: BLE001
                log.warning("could not remove wg peer %s after failed spawn", pub[:12] + "…")
        return False


def run_loop(cfg: Cfg, providers: dict[str, CloudProvider], wgcfg: WireguardCfg) -> None:
    """Run until SIGTERM. Each iteration is fully self-contained — no state
    is carried across iterations except the `idle_since` tracking dict below,
    which is rebuilt from scratch when it makes sense to."""

    # Per-VM idle tracking. Key = VM name. Value = first wall-clock time we
    # observed "pool has no queue AND this VM belongs to that pool".
    # Re-derived lazily every loop iteration so a scaler restart costs at
    # most one scale_down_idle_seconds of extra VM lifetime.
    idle_tracker: dict[str, datetime] = {}

    while not _stop:
        try:
            iteration(cfg, providers, wgcfg, idle_tracker)
        except Exception:  # noqa: BLE001
            log.exception("iteration failed; sleeping and trying again")
        # Naive sleep — fine for poll intervals in the 10s–60s range.
        for _ in range(cfg.global_.poll_interval_seconds):
            if _stop:
                break
            time.sleep(1)


def iteration(
    cfg: Cfg, providers: dict[str, CloudProvider], wgcfg: WireguardCfg,
    idle_tracker: dict[str, datetime],
) -> None:
    """One control-loop tick. See module docstring for the decision tree."""
    queues = list_platform_queues(cfg.global_.scheduler_state_grpc)

    # Merge the managed-VM view across every configured provider. A provider
    # that errors on a tick (transient API blip) is logged and skipped — we
    # act on the providers that did answer rather than aborting the whole tick.
    vms: list[ManagedVM] = []
    for pname, prov in providers.items():
        try:
            vms.extend(prov.list_managed())
        except Exception:  # noqa: BLE001
            log.exception("provider %s list_managed failed — skipping it this tick", pname)

    log.info(
        "tick: %d platform queues, %d managed VMs (dry_run=%s)",
        len(queues), len(vms), DRY_RUN,
    )

    # WireGuard hub peer reconciliation: make the hub's peers match live AWS
    # workers. Heals a scaler/hub restart (re-add) and prunes peers whose
    # worker died without a clean reap (remove). No-op when wg is disabled.
    if wgcfg.enabled and not DRY_RUN:
        expected = {v.wg_pubkey: v.wg_ip for v in vms
                    if v.provider == "aws" and v.wg_pubkey and v.wg_ip}
        try:
            wireguard.reconcile_peers(wgcfg.iface, expected)
        except Exception:  # noqa: BLE001
            log.exception("wg peer reconcile failed (continuing)")

    used_wg_ips: set[str] = {v.wg_ip for v in vms if v.wg_ip}

    vms_by_pool: dict[str, list[ManagedVM]] = {}
    for v in vms:
        vms_by_pool.setdefault(v.pool, []).append(v)

    now = _now()
    total_vms = len(vms)

    # --- scale-up path ---------------------------------------------------
    for pool_name, pool in cfg.pools.items():
        q = _match_pool(queues, pool)
        pool_vms = vms_by_pool.get(pool_name, [])
        current_pool_vms = len(pool_vms)

        queued = q.queued if q else 0
        executing = q.executing if q else 0
        idle = q.idle if q else 0
        workers_total = q.workers_total if q else 0

        log.info(
            "  pool=%s queued=%d executing=%d idle=%d workers=%d vms=%d min=%d max=%d",
            pool_name, queued, executing, idle, workers_total, current_pool_vms,
            pool.min_nodes, pool.max_nodes,
        )

        # Decide whether queue pressure is high enough to justify spawning
        # on its own. A pool with `min_nodes > 0` spawns even when the queue
        # is quiet — the floor always applies. A pool with no matching
        # platform queue (cold scheduler, no action yet submitted) still
        # spawns iff it has a min_nodes floor.
        below_floor = current_pool_vms < pool.min_nodes
        queue_hot = q is not None and queued >= cfg.global_.scale_up_threshold

        if not below_floor and not queue_hot:
            # Nothing to do this tick for this pool. Idle bookkeeping is
            # owned by the scale-down loop below — keeping it in one place
            # avoids the two halves stomping on each other's `idle_tracker`.
            continue

        # Size the fleet.
        #
        # `desired_from_queue` = enough VMs to dispatch every in-flight action
        # concurrently. "In-flight" = queued (waiting) + executing (already
        # assigned to a worker). We divide by the pool's per-VM concurrency
        # and round up.
        #
        # Why include executing in the numerator: during a long action the
        # scheduler reports `executing > 0, queued = 0` even when total work
        # is still high. If we only counted queued, we would undershoot the
        # desired fleet and let the queue drain too slowly. Counting both
        # self-regulates: as workers register and start processing, queued
        # drops and executing rises, total stays ~constant.
        #
        # The `max(min_nodes, ...)` clamp is the warm-node floor that keeps
        # Bazel from hitting FAILED_PRECONDITION on an empty platform queue.
        total_in_flight = queued + executing
        desired_from_queue = -(-total_in_flight // pool.concurrency)   # ceil div
        desired_vms = max(pool.min_nodes, desired_from_queue)
        desired_vms = min(desired_vms, pool.max_nodes)

        remaining_global_budget = cfg.global_.max_total_nodes - total_vms
        if remaining_global_budget <= 0:
            log.warning(
                "  global max_total_nodes=%d reached — not spawning",
                cfg.global_.max_total_nodes,
            )
            break
        desired_vms = min(desired_vms, current_pool_vms + remaining_global_budget)

        to_spawn = max(0, desired_vms - current_pool_vms)
        if to_spawn == 0:
            if current_pool_vms >= pool.max_nodes and total_in_flight > 0:
                log.info(
                    "  pool=%s at max_nodes=%d (desired=%d) — queue will drain via existing VMs",
                    pool_name, pool.max_nodes, desired_vms,
                )
            continue

        # Throttle cold-starts: default 1 VM per tick so we observe each VM
        # register before committing to the next one. Raise via env for fast
        # release-matrix warm-up.
        to_spawn = min(to_spawn, SPAWN_THROTTLE_PER_POOL)

        log.info(
            "  pool=%s decision: desired=%d current=%d → spawning %d this tick (throttle=%d)",
            pool_name, desired_vms, current_pool_vms, to_spawn, SPAWN_THROTTLE_PER_POOL,
        )

        if DRY_RUN:
            log.warning(
                "  [DRY_RUN] would spawn %d vm(s) for pool=%s queued=%d executing=%d desired=%d current=%d",
                to_spawn, pool_name, queued, executing, desired_vms, current_pool_vms,
            )
            continue

        for i in range(to_spawn):
            if total_vms >= cfg.global_.max_total_nodes:
                log.warning(
                    "  global max_total_nodes=%d reached mid-spawn — stopping early",
                    cfg.global_.max_total_nodes,
                )
                break
            # Suffix only when bursting >1 VM in the same second, so single-VM
            # spawns keep their compact existing name format.
            suffix = f"-{i+1:02d}" if to_spawn > 1 else ""
            hostname_ts = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
            hostname = f"bb-worker-{sanitize_pool_slug(pool.name)}-{hostname_ts}{suffix}"

            spawned = False
            if pool.provider == "aws":
                # AWS is the primary cloud for this pool (not used by any pool
                # today; kept symmetric with the fallback path).
                if not _pool_aws_fallback_ok(pool, cfg, providers, wgcfg):
                    log.error(
                        "  pool=%s provider=aws but AWS/WireGuard not configured — skipping",
                        pool_name,
                    )
                    break
                spawned = _spawn_aws(cfg, providers, wgcfg, pool, hostname, suffix, used_wg_ips)
            else:
                # Hetzner primary. On region exhaustion, fall back to AWS
                # Graviton for eligible aarch64 pools.
                user_data = render_user_data(
                    worker_src=WORKER_SRC,
                    worker_hostname=hostname,
                    central_private_ip=cfg.global_.scheduler_private_ip or "",
                    central_public_url=cfg.global_.scheduler_public_url or "",
                    pool_name=pool.name,
                    runner_image=pool.runner_image,
                    container_image=pool.container_image,
                    bazel_pool_value=pool.bazel_pool_value,
                )
                try:
                    providers["hetzner"].create_worker(
                        pool=pool, global_=cfg.global_, user_data=user_data, name_suffix=suffix,
                    )
                    spawned = True
                except RuntimeError as e:
                    # HetznerOps.create_worker raises RuntimeError ONLY when the
                    # whole region try-chain is exhausted — exactly the capacity
                    # condition the AWS fallback exists for.
                    if _pool_aws_fallback_ok(pool, cfg, providers, wgcfg):
                        log.warning(
                            "  pool=%s: %s — falling back to AWS Graviton", pool_name, e
                        )
                        spawned = _spawn_aws(cfg, providers, wgcfg, pool, hostname, suffix, used_wg_ips)
                    else:
                        log.error("  pool=%s: %s (no AWS fallback configured)", pool_name, e)
                except Exception:  # noqa: BLE001
                    log.exception("hetzner spawn failed for pool=%s", pool_name)

            if spawned:
                total_vms += 1
            else:
                break  # stop this pool's spawn burst, try again next tick

    # --- scale-down path -------------------------------------------------
    # Running count of live VMs per pool, decremented as we delete. Keeps
    # us from reaping below `min_nodes` even when multiple VMs in the same
    # pool cross their idle threshold in the same tick.
    live_per_pool: dict[str, int] = {
        pool_name: len(vms_by_pool.get(pool_name, []))
        for pool_name in cfg.pools
    }
    for vm in vms:
        pool = cfg.pools.get(vm.pool)
        if pool is None:
            log.warning("  managed vm %s has unknown pool=%r — leaving alone", vm.name, vm.pool)
            continue
        q = _match_pool(queues, pool)
        # Pool has work in flight or queued — not idle, keep the VM.
        # We deliberately do NOT key off has_workers here: idle workers with
        # no queued/executing operations ARE the scale-down target.
        if q and q.is_busy:
            idle_tracker.pop(vm.name, None)
            continue

        # Warm-node floor: never reap below min_nodes. The "oldest VMs first"
        # ordering is implicit — we iterate `vms` which hcloud returns in
        # creation order, so newer VMs hit the delete path last. For a
        # min_nodes=1 pool that means the original warm VM is preserved and
        # the burst VMs get reaped. Close enough for now; revisit if we want
        # explicit "keep youngest" semantics.
        if live_per_pool.get(vm.pool, 0) <= pool.min_nodes:
            log.info(
                "  vm=%s idle but pool=%s at min_nodes=%d — keeping",
                vm.name, vm.pool, pool.min_nodes,
            )
            idle_tracker.pop(vm.name, None)
            continue

        idle_since = idle_tracker.setdefault(vm.name, now)
        idle_for = (now - idle_since).total_seconds()

        if idle_for < cfg.global_.scale_down_idle_seconds:
            log.info(
                "  vm=%s idle_for=%ds (threshold=%ds) — keeping",
                vm.name, int(idle_for), cfg.global_.scale_down_idle_seconds,
            )
            continue

        if DRY_RUN:
            log.warning(
                "  [DRY_RUN] would delete vm=%s idle_for=%ds",
                vm.name, int(idle_for),
            )
            continue

        prov = providers.get(vm.provider)
        if prov is None:
            log.warning("  vm=%s has unknown provider=%r — leaving alone", vm.name, vm.provider)
            continue
        try:
            prov.delete_worker(vm)
            # Tear down the worker's WireGuard hub peer (AWS workers only). If
            # this fails, reconcile_peers() prunes it on a later tick.
            if wgcfg.enabled and vm.provider == "aws" and vm.wg_pubkey:
                try:
                    wireguard.remove_peer(wgcfg.iface, vm.wg_pubkey)
                except Exception:  # noqa: BLE001
                    log.warning("could not remove wg peer for %s (reconcile will prune)", vm.name)
            idle_tracker.pop(vm.name, None)
            live_per_pool[vm.pool] = max(0, live_per_pool.get(vm.pool, 0) - 1)
        except Exception:  # noqa: BLE001
            log.exception("delete failed for vm=%s", vm.name)


# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------
def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-5s %(name)s: %(message)s",
    )

    if not POOLS_CONFIG.exists():
        log.error("pools config not found at %s", POOLS_CONFIG)
        return 2
    if not WORKER_SRC.exists():
        log.error("worker source tree not mounted at %s", WORKER_SRC)
        return 2

    cfg = load_config(POOLS_CONFIG)
    log.info(
        "loaded config: %d pools, dry_run=%s, poll=%ds, idle_threshold=%ds",
        len(cfg.pools), DRY_RUN,
        cfg.global_.poll_interval_seconds,
        cfg.global_.scale_down_idle_seconds,
    )
    if cfg.global_.scheduler_private_ip is None or cfg.global_.scheduler_public_url is None:
        log.warning(
            "scheduler_private_ip / scheduler_public_url unset — "
            "scaler cannot render a usable cloud-init. Fix ondemand-pools.yaml "
            "or run create-central.sh to fill them in."
        )

    # Provider registry. Hetzner is always present (the primary). AWS Graviton
    # is added only when `aws.enabled` is set AND the WireGuard hub is wired up
    # — otherwise an aarch64 pool's `aws_instance_type` is inert and Hetzner
    # capacity exhaustion just surfaces as a logged error (today's behaviour).
    providers: dict[str, CloudProvider] = {"hetzner": HetznerOps(HCLOUD_TOKEN)}

    g = cfg.global_
    wg_ready = bool(g.wg_hub_pubkey and g.wg_hub_endpoint and g.wg_allowed_ips)
    aws_ready = bool(g.aws_subnet_id and g.aws_security_group_ids and g.aws_ami_id)
    wgcfg = WireguardCfg(
        enabled=g.aws_enabled and wg_ready,
        iface=g.wg_iface,
        hub_pubkey=g.wg_hub_pubkey,
        hub_endpoint=g.wg_hub_endpoint,
        cidr=g.wg_cidr,
        hub_ip=g.wg_hub_ip,
        allowed_ips=g.wg_allowed_ips,
    )

    if g.aws_enabled:
        if not (wg_ready and aws_ready):
            log.error(
                "aws.enabled=true but config incomplete (wg_ready=%s aws_ready=%s) — "
                "AWS fallback DISABLED. Need wg hub pubkey/endpoint/allowed_ips + "
                "aws subnet_id/security_group_ids/ami_id. Run scripts/setup-wireguard-hub.sh "
                "and fill the aws: block in ondemand-pools.yaml / .env.",
                wg_ready, aws_ready,
            )
        else:
            providers["aws"] = AwsOps(region=g.aws_region)
            log.info(
                "AWS Graviton fallback ENABLED: region=%s spot=%s wg_iface=%s hub_endpoint=%s allowed_ips=%s",
                g.aws_region, g.aws_use_spot, g.wg_iface, g.wg_hub_endpoint, g.wg_allowed_ips,
            )
    else:
        aws_pools = [p for p in cfg.pools.values() if p.aws_fallback]
        if aws_pools:
            log.warning(
                "%d pool(s) set aws_fallback but aws.enabled is false — "
                "those pools will NOT fall back to AWS on Hetzner exhaustion.",
                len(aws_pools),
            )

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    run_loop(cfg, providers, wgcfg)
    log.info("exited cleanly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
