# `scaler/` — BuildBarn on-demand worker autoscaler

Python daemon that runs on the `bb-psmdb-ondemand` central node and manages
the Hetzner Cloud worker fleet based on live scheduler queue state.

This is the Phase 2 MVP — minimal but complete: it reads queue state,
makes sensible spawn/delete decisions, and ships them to Hetzner. What it
does *not* do yet is documented in the "Not yet implemented" section below.

See [`../../buildbarn-ondemand-scaler.md`](../../buildbarn-ondemand-scaler.md)
§5.2–5.7 for the long-form design.

## Operator-facing contract

| Thing | Value |
| ----- | ----- |
| Where it runs | inside `docker compose` on the central, service name `scaler` |
| Input | `BuildQueueState` gRPC at `127.0.0.1:8984` (scheduler), pool YAML at `/config/ondemand-pools.yaml` |
| Output | Hetzner API calls (`servers.create`, `servers.delete`) |
| State | none — labels on Hetzner VMs (`psmdb.managed-by=bb-ondemand-scaler`) are the sole source of truth |
| Safety default | `SCALER_DRY_RUN=true` — logs decisions without executing them |
| Cost guard | `global.max_total_nodes` + `global.max_cost_per_hour_eur` in pool YAML |

## Files

| File | Purpose |
| ---- | ------- |
| `scaler.py` | Main daemon: config load, control loop, decide, act. |
| `bootstrap.py` | Renders a fully self-contained cloud-init user-data from the `worker/` tree. Importable (for scaler.py) and runnable (for dev self-test). |
| `Dockerfile` | `python:3.12-slim-bookworm` + pinned `grpcurl` + pip deps. |
| `requirements.txt` | `hcloud-python` + `PyYAML`, both pinned. |

## Decision logic (concise)

For each pool P in `ondemand-pools.yaml`:

**Scale up.**  Spawn a VM for pool P if either:

1. `current_pool_vms < P.min_nodes` — warm-node floor, applies regardless of
   queue state (including when the scheduler has no matching platform queue
   yet because no action has been submitted), OR
2. `queued >= scale_up_threshold` — queue pressure exceeds the noise floor.

When spawning, size the fleet from live queue pressure with the floor clamp:

```
total_in_flight    = queued + executing
desired_from_queue = ceil(total_in_flight / P.concurrency)
desired_vms        = max(P.min_nodes, desired_from_queue)
desired_vms        = min(desired_vms, P.max_nodes, global.max_total_nodes)
to_spawn           = min(desired_vms - current_pool_vms, SPAWN_THROTTLE_PER_POOL)
```

Including `executing` in the numerator stops the fleet from under-sizing
during long actions (where the scheduler reports `queued=0 executing>0`).
`SPAWN_THROTTLE_PER_POOL` defaults to **1**, so each tick spawns at most one
new VM per pool — cold-starts proceed serially and a burst that evaporates
during boot costs one unnecessary VM, not `N`. Raise via env var once the
cold-start pipeline is trusted.

**Scale down.**  If the queue is not busy (`queued == 0 and executing == 0`)
and a VM labelled with P exists, track its first-observed idle time. Once
that exceeds `scale_down_idle_seconds`, delete the VM — but never below
`P.min_nodes` live VMs. Pools with `min_nodes > 0` always keep that many
warm workers; on the current setup every pool is `min_nodes: 0` because
the predeclared-queue plumbing (next section) removes the need for a warm
floor.

### Cold-start race and why we use `predeclaredPlatformQueues`

Bazel's `GrpcRemoteExecutor` classifies `FAILED_PRECONDITION: No workers exist`
as a permanent failure and never retries it. Without mitigation, the first
`bazel build` against a cold scheduler + empty pool races the scaler's 30 s
poll + ~2 min VM boot and dies on action #1.

The MVP used `min_nodes: 1` on `ubuntu-noble-x86_64` as a stopgap — one cpx42
warm 24/7 (~€23/mo). That worked but does not scale to 11 release-matrix
pools (~€250/mo).

The current fix is **`predeclaredPlatformQueues`** in `scheduler.jsonnet`
(see `compose/config/scheduler.jsonnet`). The scheduler creates each pool's
queue at boot, independent of worker registration. Bazel's first `Execute`
succeeds (action is queued), the scaler observes `queued > 0` on its next
tick, spawns a VM, and the action runs once the worker registers — Bazel's
default 3600 s `--remote_timeout` comfortably absorbs the ~2 min wait.

`min_nodes: 0` is therefore sufficient for every pool once the predeclared
queue is wired in. The YAML still supports `min_nodes` as an override for
pools where warm capacity genuinely beats cold-start latency; we leave it
at 0 by default.

**Sync is by construction.** `create-central.sh`'s `bake_predeclared()`
step reads `ondemand-pools.yaml` and generates
`compose/config/predeclared.libsonnet` (imported by `scheduler.jsonnet`),
emitting one entry per pool with a non-null `container_image_sha`. YAML
is the only knob to turn; there is nothing to drift. A pool with
`container_image_sha: null` is scaffolded but skipped — the YAML header
documents the priming flow to activate it.

## Why grpcurl and not compiled protos

bb-scheduler enables gRPC server reflection by default. grpcurl uses that to
serialize arguments and parse responses without a local `.proto` copy, so
bumping the bb-scheduler image does not force us to re-generate Python
stubs. The tradeoff is a ~50 ms fork+exec per call; at `poll=30 s` we do
one call per tick, which is negligible.

If this becomes a pain point (say, we want sub-second scheduling), swap in
compiled protos via `grpcio-tools` — the `grpcurl` subprocess is isolated
in `scaler.scheduler` (see `list_platform_queues()` in `scaler.py`) and
shouldn't take more than ~30 lines to replace.

## Why the scaler embeds worker configs in cloud-init

The manual tool (`scripts/spawn-worker.sh`) rsyncs the rendered `worker/`
tree into the VM over SSH after cloud-init completes. The scaler cannot do
that cleanly from inside a container (needs SSH key provisioning, known_hosts
churn on recycled IPs, etc.), so `bootstrap.py` produces a **self-contained
#cloud-config** with every file under `write_files:` and
`docker compose up -d` as the final `runcmd` step.

Both paths read the same `worker/` directory on the central, so there is
one source of truth for the config tree. When the manual path says "working",
the automatic path ships the same bytes.

## Debugging

```bash
# Tail live decisions
docker compose logs -f scaler

# Inspect a single cloud-init render without going near Hetzner
docker compose exec scaler python /app/bootstrap.py

# Check labelled VMs directly
hcloud server list --selector psmdb.managed-by=bb-ondemand-scaler

# Manually delete a runaway VM
hcloud server delete <id>    # scaler will re-observe the absence on its next tick
```

`SCALER_DRY_RUN=true` + `docker compose logs -f scaler` is the primary
troubleshooting loop during rollout. Every spawn/delete decision is logged
with the pool name, queued count, and reason — the dry-run output is meant
to look identical to the live output minus the actual API call.

## Not yet implemented (Phase 2 → Phase 3)

| Feature | Why not MVP | Where it'll go |
| ------- | ----------- | -------------- |
| Region try-chain (hel1 → nbg1 → fsn1) for capacity errors | Current code tries each region but stops on first success — that's enough for `cpx42` in `hel1`; add per-region jitter later | `HetznerOps.create_worker()` |
| aarch64 pools (CAX server types, arm64 runner images) | x86_64 is the proven path; aarch64 needs image verification + cloud-init check on arm64 host | new pool entries in `ondemand-pools.yaml` with `bazel_pool_value: aarch64` and `server_type: cax*` |
| Multi-branch SHAs per pool (master + 8.0 + 8.3 + future 9.0) | Today one pool = one SHA, mirroring one branch's `remote_execution_containers.bzl`. Clients on other branches hit `FAILED_PRECONDITION` because SHA doesn't match the predeclared queue. Open question: declare N queues per pool (one per active branch) vs pull SHAs live from each branch's `.bzl` vs relax the SHA match | likely a new `container_image_shas:` list field in `ondemand-pools.yaml` + extended `bake_predeclared()` emitting one entry per SHA, or a lightweight syncer that fetches `.bzl` per tracked branch |
| Pre-warm HTTP API (Jenkins hints) | External trigger; implement after the passive loop is trusted | new Flask endpoint on a random port, wire into compose |
| Prometheus `/metrics` | Important for production dashboards; today we rely on `docker logs` | `prometheus_client` in requirements, expose on `:9090` |
| SIGHUP reload of `ondemand-pools.yaml` | Restarting the scaler is 2 seconds, good enough for MVP | `signal.SIGHUP` handler in `run_loop()` |
| Draining (let current action finish before delete) | Workers are idempotent — Bazel retries; acceptable loss on scale-down | bb-worker `Drain` API |
| `psmdb.last-seen-idle-at` label on the VM | All state is in-process; a scaler restart costs ≤ `scale_down_idle_seconds` of extra VM lifetime | `HetznerOps.tag_idle()` |

Each of these is a ≤1-file diff on top of the MVP. Add them one at a time
with a dry-run pass in between.
