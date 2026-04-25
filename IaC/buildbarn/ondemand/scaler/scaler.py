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
from hcloud import Client as HcloudClient
from hcloud.images.domain import Image
from hcloud.locations.domain import Location
from hcloud.server_types.domain import ServerType
from hcloud.ssh_keys.domain import SSHKey
from hcloud.networks.domain import Network

from bootstrap import render_user_data

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

# Hetzner labels we attach to spawned VMs. The `managed-by` label is the
# discriminator the scaler uses to re-discover state on restart — any VM
# without it is someone else's and gets ignored.
LABEL_MANAGED = "psmdb.managed-by"
LABEL_MANAGED_VALUE = "bb-ondemand-scaler"
LABEL_POOL    = "psmdb.pool"
LABEL_VERSION = "psmdb.version"
LABEL_SPAWNED = "psmdb.spawned-at"   # unix ts at spawn time

# Hetzner server names must satisfy RFC 1123: lowercase alphanumerics and
# hyphens only, max 63 chars total. Our pool keys are up to ~46 chars
# (e.g. "amazonlinux-2023-x86_64__vmaster__9873907c9659") and contain
# underscores plus consecutive `__` separators that some validators reject.
# After we glue the `bb-worker-` prefix (10 chars) and `-<TS>` suffix
# (16 chars) we have 37 chars of budget for the pool slug. The full pool
# name is preserved losslessly via the LABEL_POOL Hetzner label — the
# server name is only for human-readable VM identification. Mirrors the
# logic in scripts/spawn-worker.sh; both must agree byte-for-byte so VMs
# spawned by either path are named consistently.
_POOL_SLUG_BUDGET = 37


def _sanitize_pool_slug(pool_name: str) -> str:
    """Return an RFC-1123-safe ≤37-char slug derived from a pool key."""
    slug = pool_name.lower().replace("_", "-")
    while "--" in slug:
        slug = slug.replace("--", "-")
    slug = slug[:_POOL_SLUG_BUDGET].rstrip("-")
    return slug


log = logging.getLogger("scaler")

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


@dataclasses.dataclass
class ManagedVM:
    """A Hetzner VM the scaler owns, reconstructed from labels."""
    id: int
    name: str
    pool: str
    version: str
    spawned_at: datetime
    status: str   # from hcloud: running, initializing, etc.
    idle_since: datetime | None = None   # set by the scale-down decider


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
        )
    return Cfg(
        global_=GlobalCfg(
            scheduler_state_grpc=g.get("scheduler_state_grpc", SCHEDULER_STATE_GRPC),
            scheduler_public_url=g.get("scheduler_public_url"),
            scheduler_private_ip=g.get("scheduler_private_ip"),
            ssh_key_ids=list(g["hcloud_ssh_key_ids"]),
            network_id=int(g["hcloud_network_id"]),
            os_image=g["hcloud_os_image"],
            region_try_chain=list(g["region_try_chain"]),
            max_total_nodes=int(g["max_total_nodes"]),
            max_cost_per_hour_eur=float(g["max_cost_per_hour_eur"]),
            poll_interval_seconds=int(g["poll_interval_seconds"]),
            scale_down_idle_seconds=int(g["scale_down_idle_seconds"]),
            scale_up_threshold=int(g["scale_up_threshold"]),
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


# ---------------------------------------------------------------------------
# Hetzner helpers.
# ---------------------------------------------------------------------------
class HetznerOps:
    """Thin wrapper over hcloud-python that encodes our labelling convention."""

    def __init__(self, token: str) -> None:
        if not token:
            raise RuntimeError("HCLOUD_TOKEN not set — scaler cannot talk to Hetzner")
        self.client = HcloudClient(token=token)

    def list_managed(self) -> list[ManagedVM]:
        """Enumerate VMs we own, by `managed-by` label."""
        # The label_selector API on hcloud-python accepts "key=value" form.
        servers = self.client.servers.get_all(
            label_selector=f"{LABEL_MANAGED}={LABEL_MANAGED_VALUE}"
        )
        out: list[ManagedVM] = []
        for s in servers:
            labels = s.labels or {}
            try:
                spawned_ts = int(labels.get(LABEL_SPAWNED, "0"))
                spawned_dt = datetime.fromtimestamp(spawned_ts, tz=timezone.utc)
            except (ValueError, TypeError):
                spawned_dt = datetime.now(timezone.utc)
            out.append(ManagedVM(
                id=s.id,
                name=s.name,
                pool=labels.get(LABEL_POOL, ""),
                version=labels.get(LABEL_VERSION, ""),
                spawned_at=spawned_dt,
                status=s.status,
            ))
        return out

    def create_worker(
        self,
        *,
        pool: PoolCfg,
        global_: GlobalCfg,
        user_data: str,
        name_suffix: str = "",
    ) -> int:
        """Create a VM with region fallback. Returns the new server ID.

        `name_suffix` is appended to the second-resolution timestamp and lets
        the caller disambiguate VMs spawned back-to-back within the same
        wall-clock second (relevant when SPAWN_THROTTLE_PER_POOL > 1).
        """
        ts = int(time.time())
        pool_slug = _sanitize_pool_slug(pool.name)
        name = f"bb-worker-{pool_slug}-{time.strftime('%Y%m%d-%H%M%S', time.gmtime(ts))}{name_suffix}"
        labels = {
            LABEL_MANAGED: LABEL_MANAGED_VALUE,
            LABEL_POOL: pool.name,
            LABEL_VERSION: pool.psmdb_version,
            LABEL_SPAWNED: str(ts),
            "project": "psmdb-buildbarn",
            "role": "bb-worker",
        }
        ssh_keys = [SSHKey(id=kid) for kid in global_.ssh_key_ids]
        networks = [Network(id=global_.network_id)]

        last_err: Exception | None = None
        for region in global_.region_try_chain:
            try:
                resp = self.client.servers.create(
                    name=name,
                    server_type=ServerType(name=pool.server_type),
                    image=Image(name=global_.os_image),
                    location=Location(name=region),
                    ssh_keys=ssh_keys,
                    networks=networks,
                    user_data=user_data,
                    labels=labels,
                    start_after_create=True,
                )
                log.info(
                    "spawned %s (id=%s) in %s, type=%s, pool=%s",
                    name, resp.server.id, region, pool.server_type, pool.name,
                )
                return resp.server.id
            except Exception as e:  # noqa: BLE001
                last_err = e
                log.warning("create in %s failed: %s — trying next region", region, e)
        raise RuntimeError(f"all regions exhausted; last error: {last_err}")

    def delete_worker(self, vm: ManagedVM) -> None:
        log.info("deleting vm %s (id=%d, pool=%s)", vm.name, vm.id, vm.pool)
        server = self.client.servers.get_by_id(vm.id)
        if server is not None:
            server.delete()


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


def run_loop(cfg: Cfg, hz: HetznerOps) -> None:
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
            iteration(cfg, hz, idle_tracker)
        except Exception:  # noqa: BLE001
            log.exception("iteration failed; sleeping and trying again")
        # Naive sleep — fine for poll intervals in the 10s–60s range.
        for _ in range(cfg.global_.poll_interval_seconds):
            if _stop:
                break
            time.sleep(1)


def iteration(cfg: Cfg, hz: HetznerOps, idle_tracker: dict[str, datetime]) -> None:
    """One control-loop tick. See module docstring for the decision tree."""
    queues = list_platform_queues(cfg.global_.scheduler_state_grpc)
    vms = hz.list_managed()

    log.info(
        "tick: %d platform queues, %d managed VMs (dry_run=%s)",
        len(queues), len(vms), DRY_RUN,
    )

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
            pool_slug = _sanitize_pool_slug(pool.name)
            hostname = f"bb-worker-{pool_slug}-{hostname_ts}{suffix}"
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
                hz.create_worker(
                    pool=pool,
                    global_=cfg.global_,
                    user_data=user_data,
                    name_suffix=suffix,
                )
                total_vms += 1
            except Exception:  # noqa: BLE001
                log.exception("spawn failed for pool=%s", pool_name)
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

        try:
            hz.delete_worker(vm)
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

    hz = HetznerOps(HCLOUD_TOKEN)

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    run_loop(cfg, hz)
    log.info("exited cleanly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
