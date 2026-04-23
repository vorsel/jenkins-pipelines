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
       scale_up   — queue has work but no workers AND we haven't already
                    spawned one that's still booting
       scale_down — a managed VM has been idle (no queued/active work for
                    its pool) for more than scale_down_idle_seconds
  4. Executes those decisions by calling hcloud, UNLESS SCALER_DRY_RUN=true
     (the default until the operator switches it off).

Design notes:

  * No external state — Hetzner server labels are the source of truth. A
    scaler restart rebuilds its view by listing labelled servers.
  * BuildQueueState is consumed by shelling out to grpcurl. The alternative
    (compiling buildbarn/bb-remote-execution protos into Python) is more
    robust but adds 150 lines of build wiring; grpcurl via reflection costs
    ~50 ms per call and survives schema changes in the protos.
  * Scale-up is intentionally NAIVE in this MVP — one VM per pool when a
    queue appears, no attempt to fill --jobs=96 with multiple VMs. Multi-VM
    scaling, pre-warm API, and region fallback come in Phase 3.

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

# Hetzner labels we attach to spawned VMs. The `managed-by` label is the
# discriminator the scaler uses to re-discover state on restart — any VM
# without it is someone else's and gets ignored.
LABEL_MANAGED = "psmdb.managed-by"
LABEL_MANAGED_VALUE = "bb-ondemand-scaler"
LABEL_POOL    = "psmdb.pool"
LABEL_VERSION = "psmdb.version"
LABEL_SPAWNED = "psmdb.spawned-at"   # unix ts at spawn time

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
    container_image_sha: str
    psmdb_version: str
    runner_image_base: str
    server_type: str
    concurrency: int
    min_nodes: int
    max_nodes: int

    @property
    def runner_image(self) -> str:
        """Full image reference for `docker compose pull`."""
        return f"{self.runner_image_base}:{self.psmdb_version}"


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

    def container_image_sha(self) -> str | None:
        """Extract the SHA from the docker:// reference used in PSMDB platforms."""
        ci = self.platform_props.get("container-image", "")
        # docker://...@sha256:<hex>
        marker = "@sha256:"
        idx = ci.find(marker)
        return ci[idx + len(marker):] if idx >= 0 else None

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
        pools[name] = PoolCfg(
            name=name,
            container_image_sha=pc["container_image_sha"],
            psmdb_version=str(pc["psmdb_version"]),
            runner_image_base=pc["runner_image_base"],
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
    included on failure — the scaler caller should catch and log, never
    silently swallow, so schema drift shows up in operator logs.
    """
    cmd = [
        "grpcurl",
        "-plaintext",
        "-d", body,
        endpoint,
        f"{BQS_SERVICE}/{method}",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return json.loads(result.stdout or "{}")


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
    ) -> int:
        """Create a VM with region fallback. Returns the new server ID."""
        ts = int(time.time())
        # Hetzner names are RFC 1123 hostnames: lowercase, hyphens, no
        # underscores. Our pool names DO contain underscores (`x86_64`), so
        # translate them out at VM-name-creation time — matches the logic
        # in scripts/spawn-worker.sh.
        pool_slug = pool.name.replace("_", "-").lower()
        name = f"bb-worker-{pool_slug}-{time.strftime('%Y%m%d-%H%M%S', time.gmtime(ts))}"
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
    for q in queues:
        if q.container_image_sha() == pool.container_image_sha:
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

        queued = q.queued if q else 0
        executing = q.executing if q else 0
        idle = q.idle if q else 0
        workers_total = q.workers_total if q else 0

        log.info(
            "  pool=%s queued=%d executing=%d idle=%d workers=%d vms=%d",
            pool_name, queued, executing, idle, workers_total, len(pool_vms),
        )

        # No matching scheduler queue at all → nothing to spawn for this pool
        # in this tick. (Idle bookkeeping is owned by the scale-down loop
        # below — keeping it in one place avoids the two halves stomping on
        # each other's `idle_tracker` entries.)
        if not q:
            continue

        # Spawn decision: queue must exceed threshold AND there must be no
        # existing capacity (registered workers OR a VM we already spawned
        # that hasn't registered yet). This is the conservative MVP — Phase 3
        # will compute ceil(queued/concurrency) for multi-VM bursts.
        if queued < cfg.global_.scale_up_threshold:
            continue
        if q.has_workers or pool_vms:
            continue
        if len(pool_vms) >= pool.max_nodes:
            log.info("  pool=%s at max_nodes=%d — not spawning", pool_name, pool.max_nodes)
            continue
        if total_vms >= cfg.global_.max_total_nodes:
            log.warning("  global max_total_nodes=%d reached — not spawning", cfg.global_.max_total_nodes)
            break

        # Decided: spawn.
        if DRY_RUN:
            log.warning(
                "  [DRY_RUN] would spawn pool=%s queued=%d (set SCALER_DRY_RUN=false to enable)",
                pool_name, queued,
            )
            continue

        hostname_ts = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
        pool_slug = pool.name.replace("_", "-").lower()
        hostname = f"bb-worker-{pool_slug}-{hostname_ts}"
        user_data = render_user_data(
            worker_src=WORKER_SRC,
            worker_hostname=hostname,
            central_private_ip=cfg.global_.scheduler_private_ip or "",
            central_public_url=cfg.global_.scheduler_public_url or "",
            pool_name=pool.name,
            runner_image=pool.runner_image,
        )
        try:
            hz.create_worker(pool=pool, global_=cfg.global_, user_data=user_data)
            total_vms += 1
        except Exception:  # noqa: BLE001
            log.exception("spawn failed for pool=%s", pool_name)

    # --- scale-down path -------------------------------------------------
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
