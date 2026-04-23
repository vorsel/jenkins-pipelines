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

- Find the scheduler platform queue whose `container-image` SHA matches
  `P.container_image_sha`.
- If the queue has **queued operations ≥ scale_up_threshold** and **zero
  workers** and **no VMs currently booting for P** and we're **under
  P.max_nodes and global.max_total_nodes**: spawn one VM.
- If the queue is **empty** and a VM labelled with P exists, track its
  first-observed idle time. Once that exceeds `scale_down_idle_seconds`,
  delete the VM.

The MVP intentionally spawns **at most one VM per pool per tick**. Multi-VM
burst scaling (needed to saturate `--jobs=96` on a release matrix) is the
next follow-up — see "Not yet implemented".

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
| Multi-VM scale-up per pool (ceil(queued / concurrency)) | Needs testing with real release-matrix queue depth; risk is over-spawning | `iteration()` scale-up loop |
| Region try-chain (hel1 → nbg1 → fsn1) for capacity errors | Current code tries each region but stops on first success — that's enough for `cpx42` in `hel1`; add per-region jitter later | `HetznerOps.create_worker()` |
| Pre-warm HTTP API (Jenkins hints) | External trigger; implement after the passive loop is trusted | new Flask endpoint on a random port, wire into compose |
| Prometheus `/metrics` | Important for production dashboards; today we rely on `docker logs` | `prometheus_client` in requirements, expose on `:9090` |
| SIGHUP reload of `ondemand-pools.yaml` | Restarting the scaler is 2 seconds, good enough for MVP | `signal.SIGHUP` handler in `run_loop()` |
| Draining (let current action finish before delete) | Workers are idempotent — Bazel retries; acceptable loss on scale-down | bb-worker `Drain` API |
| `psmdb.last-seen-idle-at` label on the VM | All state is in-process; a scaler restart costs ≤ `scale_down_idle_seconds` of extra VM lifetime | `HetznerOps.tag_idle()` |

Each of these is a ≤1-file diff on top of the MVP. Add them one at a time
with a dry-run pass in between.
