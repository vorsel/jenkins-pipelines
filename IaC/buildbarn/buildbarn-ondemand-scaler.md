# BuildBarn On-Demand Worker Scaler — Architecture & Implementation Plan

**Status:** proposal / architecture draft.
**Companion doc:** [`buildbarn-remote-execution-setup.md`](./buildbarn-remote-execution-setup.md) — the static single-platform deployment that this proposal replaces. All empirical numbers in this document are drawn from §9 and §10 of that doc (referenced inline as `§9.7` etc.).

## 1. Purpose

Replace the current **static permanent fleet** (3 workers always running regardless of demand) with an **elastic on-demand fleet** that:

1. Keeps only the central node permanently — runs `scheduler+storage+frontend+browser+Envoy+scaler`, **no local runner**. Sized as `cpx42` (8 vCPU shared, 16 GB, ~€17/mo); all state on an attached xfs volume so VM is replaceable — see §5.1 for rationale.
2. Spawns BuildBarn workers on Hetzner Cloud **only when there is work queued** for a specific `(distro, arch)` variant, and for that variant's `container-image` pool.
3. Tears workers down when the pool's queue drains and workers have been idle for `T_idle` seconds.
4. Supports **arbitrary number of pools in parallel** — at rest: 0 workers; during a dev build of one variant: ~4 workers for that variant; during a full release matrix: `Σ(variant workers) = many`.

This aligns infrastructure spend with actual build demand. Measured release-matrix usage pattern (from the `jenkins-pipelines` / `psmdb-jenkins-pipeline` jobs) is bursty: daily/weekly full-matrix runs for ~2–3 h, plus a handful of per-variant dev/master builds the rest of the time. A permanent fleet sized for the burst case is ~80% idle.

## 2. Scope (what this doc covers / does not cover)

In scope:

- Scaler daemon that decides **when and how many** workers to add/remove.
- Hetzner Cloud provisioning of per-variant worker VMs.
- Worker bootstrap via cloud-init (or similar) — Docker, BuildBarn worker+runner compose, pool-specific runner image from registry.
- Integration points with the existing BuildBarn scheduler (no fork, no protocol changes — workers join natively).
- Safety rails: quotas, cost caps, cooldown timers.
- Jenkins integration (pre-warm hooks for known release schedules).

Out of scope:

- Kubernetes / k8s autoscaler (explicit non-goal — Hetzner Cloud only, no k8s).
- Multi-provider (AWS/GCP fallback) — Hetzner only for phase 1.
- Replacing the REAPI v2.0 Envoy proxy (§7 of setup doc) — stays as is.
- **Modifying the existing static deployment** (`bb-psmdb` central + `barn-psmdb-worker-1` + `barn-psmdb-worker-2` + `psmdb-mongot`). The entire ondemand stack is built **in parallel** on freshly-created Hetzner resources. See §2.1 for why.

### 2.1 Deployment strategy — parallel green-field, zero prod risk

**The existing BuildBarn deployment (central `bb-psmdb` + three workers described in `buildbarn-remote-execution-setup.md`) is not touched during any phase of this project.** It keeps serving current Bazel traffic exactly as documented in the setup doc.

Everything in this plan — the new central host, the new `psmdb-buildbarn-cas` volume, the ondemand worker fleet, the scaler daemon, the GHA-published runner images — is created on **new, independent Hetzner resources**. Side-by-side, not replace-in-place.

Why this matters:

- **Zero rollback cost.** If anything in the ondemand design turns out to be wrong (registry pull path, scheduler state gRPC, scale-down timing, volume portability, whatever), you delete the new resources and the current prod is completely unaffected.
- **Independent cache.** The new central runs its own CAS volume, so cold-start the new fleet cannot poison or blow out the existing CAS. Both systems can coexist indefinitely.
- **Explicit cut-over later.** When ondemand is end-to-end validated, the cut-over is a single `.bazelrc` change on the client side (`--remote_executor` pointed at the new central's frontend). Old clients keep hitting the old central; new clients hit the new one.
- **No migration pressure.** We are free to create, destroy, and re-create the new fleet as many times as needed without disrupting release-critical jobs running on the current fleet.

Concrete resource naming convention (everything new gets `-ondemand` suffix or `vorsel-` prefix to be obviously distinct from the existing prod names):

| Old (untouched) | New (ondemand, this project) |
|-----------------|-------------------------------|
| server `bb-psmdb` (cpx62, hel1) | server `bb-psmdb-ondemand` (`cpx42`, hel1) |
| volume `build_buddy_psmdb_cache` (100 GB, BuildBuddy's) | volume `psmdb-buildbarn-cas-ondemand` (500 GB xfs, hel1) |
| servers `barn-psmdb-worker-1/2`, `psmdb-mongot` (permanent) | ephemeral `psmdb-bb-worker-<pool>-<timestamp>` (scaler-owned) |
| network `11374636 psmdb.cd.percona.com` (shared with old fleet) | same network is fine — or a dedicated new one if we want stricter isolation (see §5.4) |
| SSH key `htz.cd.key` (Jenkins fleet) | new SSH key `htz.cd.bb-worker.key` (§5.10) |
| `ghcr.io/...` images distributed via `docker save/load` | `ghcr.io/vorsel/psmdb-buildbarn-runners/*` (§7) |

Existing prod stays verbatim on the old names. No `docker compose down`, no jsonnet edits, no SSH into `bb-psmdb` / `worker-1` / `worker-2` / `psmdb-mongot`. **Only new machines.**

## 3. Baseline we are building on

From empirical validation in `buildbarn-remote-execution-setup.md`:

| Property | Measured value | Source |
|----------|----------------|--------|
| Cold `install-dist-test` per variant | ~30 min on 60 slots | §9.7 PoC runner image validation |
| Warm `install-dist-test` per variant | ~3 min (10,330/10,330 AC hits) | §9.7 |
| `cc1plus` peak RSS on PSMDB templates | ~2–3 GB | §9.7 second variant (OOM evidence) |
| Recommended `concurrency` on `cpx51` (16c / 32GB) | `24` with +32 GB swap | §10 Improvements #6 |
| Bazel invocation | `--jobs=96` (client-side upper bound) | §9.2 |
| Pool routing signal | `container-image` SHA from `bazel/platforms/remote_execution_containers.bzl` | §9.7 second-variant finding #3 |
| Per-distro runtime libs (OpenSSL, etc.) | non-hermetic — image distro matters | §9.7 second-variant finding #1 |
| Multi-pool on one bb_worker | works via multiple `runners[]` entries with distinct Unix sockets | §9.7 second-variant finding #3 |

**Architectural primitive we rely on:** BuildBarn workers are *pull-based*. A worker dials the scheduler's gRPC `:8983` and announces itself with its `platform.properties`. The scheduler has no notion of "expected workers" — if a matching worker is online, operations are dispatched; if not, `FAILED_PRECONDITION: No workers exist for instance name prefix "hardlinking" platform {...}` surfaces on the client. Workers may come and go any time. This makes the autoscaler straightforward — it doesn't need to coordinate with the scheduler about workforce.

### 3.1 Variant matrix — 11 runner images

The authoritative source of truth is the parallel-stages block in [`jenkins-pipelines/psmdb/jenkins/percona-server-for-mongodb-8.3.groovy`](../../psmdb/jenkins/percona-server-for-mongodb-8.3.groovy) — specifically the `buildStage("<docker-image>", "--build_*=1")` invocations inside `stage('Build PSMDB RPMs/DEBs/Binary tarballs')`. Each unique `(docker-base, arch)` pair is one runner image; multiple Jenkins stages can (and do) share the same image.

| # | Runner image (registry path under `ghcr.io/vorsel/psmdb-buildbarn-runners/`) | Base image | Arch | Jenkins stages covered | MongoDB `REMOTE_EXECUTION_CONTAINERS` key + SHA |
|---|---|---|---|---|---|
| 1 | `oraclelinux-8-x86_64` | `oraclelinux:8` | x86_64 | `build_rpm` (OL8), `build_tarball` (OL8, glibc 2.28), `build_src_rpm`, `build_src_tarball`, `get_sources` | `rhel8` → `f78343a8...` |
| 2 | `oraclelinux-8-aarch64` | `oraclelinux:8` | aarch64 | `build_rpm` (OL8 aarch64) | `rhel8` (same key, aarch64 pulls via manifest) |
| 3 | `oraclelinux-9-x86_64` | `oraclelinux:9` | x86_64 | `build_rpm` (OL9), `build_tarball` (OL9, glibc 2.34) | `rhel9` → `908f34e9...` |
| 4 | `oraclelinux-9-aarch64` | `oraclelinux:9` | aarch64 | `build_rpm` (OL9 aarch64) | `rhel9` (aarch64) |
| 5 | `amazonlinux-2023-x86_64` | `amazonlinux:2023` | x86_64 | `build_rpm` (AL2023), `build_tarball` (AL2023, glibc 2.34) | `amazon_linux_2023` → `88544e21...` |
| 6 | `amazonlinux-2023-aarch64` | `amazonlinux:2023` | aarch64 | `build_rpm` (AL2023 aarch64) | `amazon_linux_2023` (aarch64) |
| 7 | `ubuntu-jammy-x86_64` | `ubuntu:jammy` | x86_64 | `build_deb` (Jammy), `build_tarball` (Jammy, glibc 2.35), `build_src_deb` | `ubuntu22` → `c1e42910...` |
| 8 | `ubuntu-jammy-aarch64` | `ubuntu:jammy` | aarch64 | `build_deb` (Jammy aarch64) | `ubuntu22` (aarch64) |
| 9 | `ubuntu-noble-x86_64` | `ubuntu:noble` | x86_64 | `build_deb` (Noble), `build_tarball` (Noble, glibc 2.39) | `ubuntu24` → `f1bd9610...` **validated (§9.7)** |
| 10 | `ubuntu-noble-aarch64` | `ubuntu:noble` | aarch64 | `build_deb` (Noble aarch64) | `ubuntu24` (aarch64) |
| 11 | `debian-bookworm-x86_64` | `debian:bookworm` | x86_64 | `build_deb` (Bookworm), `build_tarball` (Bookworm, glibc 2.36) | `debian12` → `d1df0fd7...` **validated (§9.7)** |

Notes:

- **11, not 17.** Earlier back-of-envelope in this doc said "17 pools" by Σ(every distro × every arch). The actual PSMDB 8.3 release matrix has no Debian Bookworm aarch64 stage, so one combination drops; the numbers in §8 Phase 4 and §11 cost model are pinned to 11.
- **Validated today: images 9 and 11** (§9.7 of setup doc, empirical cold build through BuildBarn). Images 1–8 and 10 have never been built yet, but `install_deps()` for their docker bases runs in every Jenkins pipeline execution on a fresh container and has for years — so confidence is high that baking them into Dockerfiles is mechanical.
- **OL8 x86_64 is the hottest image** — 4 stages share it (rpm + tarball + source rpm + source tarball). The scaler's pool config should probably give it a higher `min_nodes` once usage data rolls in (§Phase 4 step 18).
- **MongoDB `REMOTE_EXECUTION_CONTAINERS` SHAs** are the routing keys the Bazel client sends to the scheduler (see §9.7 of setup doc for the discovery story). One SHA per distro covers both architectures — the scheduler matches on the SHA plus whatever `Pool` property carries the arch.
- **Weekly rebuild cadence** picks up upstream CVE updates. Build all 11 in one matrix job, push with both `:<sha>` and `:latest` tags (§7 workflow).
- **Registry path** during dev phase: `ghcr.io/vorsel/psmdb-buildbarn-runners/<runner-image>:latest`. Production flips to `ghcr.io/percona/...` per §7.

**Second primitive — queue state read API:** the scheduler exposes `BuildQueueState` gRPC on `:8984` (see upstream [`scheduler.jsonnet`](https://raw.githubusercontent.com/buildbarn/bb-deployments/master/docker-compose/config/scheduler.jsonnet)) which returns structured protobuf messages with `(queued, in-flight, idle workers)` counters per platform queue. The scaler uses this as its decision input. This is *not* Prometheus `/metrics` (that port exposes the HTML admin UI only, and the real Prometheus endpoint is at `global.diagnosticsHttpServer:80` inside the scheduler container, not exposed by default). See §6 for the exact RPCs.

## 4. Target topology

```
         +------------------------------------------+
         |          barn-psmdb (permanent)          |
         |          cpx42 · 8c shared / 16 GB       |
         |          hel1 · public + private IP      |
         |                                          |
         | frontend : 8980                          |
         | storage-0, storage-1 (CAS+AC+FSAC)       |
         |   → NEW volume `psmdb-buildbarn-cas`     |
         |     500 GB xfs, hel1 (all state incl.    |
         |     configs & secrets lives here →       |
         |     VM is fully replaceable)             |
         | scheduler : 8982 (client gRPC)           |
         |           : 8983 (worker gRPC)           |
         |           : 8984 (buildQueueState gRPC)  |
         |           : 7982 (admin HTML UI)         |
         |           : 9982 (Prometheus /metrics)*  |
         | browser  : 7984                          |
         | Envoy REAPI v2.0 proxy : 8981            |
         | scaler daemon : 9090 (own /metrics)      |
         |                                          |
         | No local runner. All compile lives on    |
         | ephemeral ondemand workers.              |
         +------------------+-----------------------+
                            |
                            | private network `psmdb.cd.percona.com` (ID 11374636)
                            | gRPC :8983 (pull-based worker→scheduler)
                            |
        +-------------------+----------------+----------------+
        |                   |                |                |
 +------v------+     +------v------+   +-----v-------+  +-----v-------+
 | worker-A    |     | worker-B    |   | worker-C    |  | worker-D    |
 | cpx51 x86   |     | cpx51 x86   |   | cax41 arm   |  | cax41 arm   |
 | private IP  |     | private IP  |   | private IP  |  | private IP  |
 | only        |     | only        |   | only        |  | only        |
 | pool:       |     | pool:       |   | pool:       |  | pool:       |
 |   noble24   |     |  bookworm12 |   | noble24arm  |  |   ol9arm    |
 | hel1/nbg1/  |     |  hel1/nbg1/ |   | hel1/nbg1/  |  | hel1/nbg1/  |
 | fsn1 try-   |     |  fsn1 try-  |   | fsn1 try-   |  | fsn1 try-   |
 | chain       |     |  chain      |   | chain       |  | chain       |
 +-------------+     +-------------+   +-------------+  +-------------+
                                 |
                                 |  (fleet size varies: 0..N)
                                 |
                                 v
        +------------------------------------------+
        | Scaler daemon (Docker service on central)|
        | - Reads queue state via gRPC :8984       |
        |   (ListPlatformQueues, ListWorkers)      |
        | - Calls Hetzner API to add/remove        |
        |   VMs per pool, with hel1→nbg1→fsn1      |
        |   region fallback on capacity errors     |
        | - Workers auto-join scheduler (pull)     |
        +------------------------------------------+
```

\* Port 9982 is exposed only if we publish the scheduler's `global.diagnosticsHttpServer` for Prometheus scraping. By default in bb-deployments it listens only on `:80` inside the container and is not mapped out. See §6 for why we prefer the `buildQueueState` gRPC on 8984 instead.

Key invariants:

- **Central node is the only always-on VM** — and is **replaceable**: all state (CAS blobs, BuildBarn configs, scaler secrets) lives on the attached `psmdb-buildbarn-cas` volume. Day-1 sizing is **`cpx42`** (8c shared / 16 GB) — see §5.1 for rationale; upgrade to `ccx*` later is 10 minutes of downtime and no data migration.
- **Scaler daemon runs as a Docker service on central** (co-located with scheduler — talks to scheduler on `localhost:8984` gRPC, no extra networking).
- **Each worker VM serves exactly one pool.** No multi-pool-per-VM in ondemand mode — simpler lifecycle, easier to reason about cost attribution, and cloud-init template needs only one `(distro, arch)` parameterisation.
  - Consequence: `worker-2`'s current setup (two pools on one VM, validated in §9.7 of setup doc) is a static-deployment pattern, not the ondemand one.
- **Workers get private IP only.** SSH-for-debug via bastion through central (see §5.10). Public-IP egress still works via Hetzner's default private-network gateway for `docker pull` from `ghcr.io` (private-only VMs still have outbound internet).
- **Registry is a hard prerequisite.** §11.7 step 1 blocker from setup doc must be resolved before this design can run. See §7 for the concrete `ghcr.io + GitHub Actions` plan.

## 5. Component detailed design

### 5.1 Permanent central node

**No runner on central.** Hosting a compiler next to the scheduler means every cc1plus OOM or GC pause blocks every Bazel action in the fleet, not just the one on the affected node. Phase 1 retires the local runner entirely.

**Sizing — VM is replaceable, state lives on an attached volume.**

The explicit design goal is **portability**: the central VM should be re-buildable from scratch in ~15 minutes given (a) a fresh Hetzner VM of any reasonable size and (b) the attached BuildBarn volume. All state (CAS, AC, FSAC, scheduler persistent queue if enabled, scaler secrets, compose files, jsonnet configs) lives on the volume. The boot disk contains only the OS and Docker. Consequence: we can swap VM types without data loss — start small, grow if proven necessary, switch to dedicated later if budget approves.

Resource budget for the central services:

| Service | CPU profile | RAM footprint |
|---------|-------------|---------------|
| scheduler | low CPU, **latency-critical** (scheduler stall → whole fleet stalls) | ~500 MB |
| storage-0, storage-1 (sharded CAS/AC/FSAC) | I/O-bound, not CPU | ~1–2 GB LRU cache each |
| frontend | light gRPC proxy | ~200 MB |
| Envoy REAPI v2.0 proxy | light TCP proxy | ~100 MB |
| browser | light | ~200 MB |
| scaler daemon (new) | trivial poll loop | ~100 MB |
| **Total** | ~2–4 cores under peak, 720 concurrent gRPC streams for 30 worker × 24 slot matrix | ~4–6 GB |

**Decision: `cpx42` (8c shared / 16 GB / 320 GB, ~€17/mo).**

Fit against our services:

| Resource | Provided | Actual need | Headroom |
|----------|----------|-------------|----------|
| vCPU | 8 shared | 2–4 under peak | ~2× — scheduler hot-path survives one noisy neighbour |
| RAM | 16 GB | ~4–6 GB services | ~10 GB left for Linux page cache over the CAS volume — hot blobs served from RAM |
| Boot disk | 320 GB local NVMe | ~10 GB (OS + Docker) | remainder unused (state is on volume, by design) |
| Network | 1 Gbps | 720 concurrent gRPC streams on matrix peak | fine (streams are light) |
| CPU generation | `cpx*2` family = 2nd-gen AMD EPYC Milan | — | same generation as `cpx51` workers → identical intra-AZ topology in hel1 |

Why `cpx42` rather than cheaper/smaller:

- **RAM is the real constraint.** Services budget is ~6 GB but page cache does the heavy lifting for hot CAS blobs. 16 GB gives ~10 GB of page cache, enough to keep the frequent action-outputs footprint hot. Going below 16 GB (`cpx41` at 8 GB RAM / `cpx31` at 8 GB) cuts page cache in half — noticeable on matrix peaks.
- **8 cores** is headroom, not strict requirement. Scheduler needs 1–2; the rest absorbs storage I/O bursts, Envoy, browser traffic, scaler loop, and shared-neighbour jitter.

Why `cpx42` rather than larger/dedicated:

- **Shared CPU** — the jitter argument for `ccx*` is theoretical; current production (`cpx62` worker with all services) validated in §9 has no jitter-induced failures. Accepting shared saves the dedicated-budget gate.
- **`cpx52`/`cpx62` (12c/16c, 24/32 GB, €27/€50)** — fine alternatives if we want extra RAM headroom. Upgrade path is simple (§portability note below); no reason to over-size on day one.

**VM is replaceable, state is portable.** If shared-CPU jitter *does* show up in scheduler p99 metrics (monitored via `/metrics` on the scaler + scheduler itself), the upgrade path is: `hcloud volume detach psmdb-buildbarn-cas → hcloud server delete bb-psmdb → hcloud server create --type ccx23 ... → hcloud volume attach psmdb-buildbarn-cas → docker compose up`. Total downtime ~10 minutes. No data migration, no config rebuild — because **all state lives on the volume**.

**CAS volume — create a new, dedicated BuildBarn volume.** The existing `build_buddy_psmdb_cache` 100 GB volume belongs to a different system (BuildBuddy, not BuildBarn) and should stay there. BuildBarn gets its own volume, sized for our actual workload from day one:

| Inputs | Value |
|--------|-------|
| Cold PSMDB build per variant | ~10,330 actions, ~X GB of CAS content |
| 11 runner images (see §3.1) | 11 variant-builds' worth of actions per matrix run |
| Actions are content-addressed and deduplicated | Only unique blobs consume space |
| Per-variant unique-blob ratio (estimate) | ~60–70% (large overlap via hermetic toolchain & shared sources) |

Rough estimate: a single full matrix cold-run produces ~50–80 GB of unique CAS content. Multiple matrix runs (with changing code) grow this over weeks. **Start with 500 GB volume.** That's:

- 5× headroom over one full matrix worth of cold content.
- ~€20/month (Hetzner volume price ~€0.04/GB-month).
- Room to run several weeks without GC.
- Can be `hcloud volume resize`-d online later (up to 10 TB).

**Filesystem: `xfs`, not ext4.** Hetzner lets you pick one at volume-create time. Rationale:

- Both support online grow (xfs via `xfs_growfs`, ext4 via `resize2fs`). Shrink is not a concern — we never need it.
- xfs wins on **every attribute that matters for BuildBarn CAS**: millions of small files (better B+tree directory indexing), high concurrent writers (per-AG allocation groups reduce lock contention vs ext4's single journal), large-file extents for occasional big blobs. This is the canonical xfs workload — it's the default filesystem on RHEL/CentOS specifically because of caches and object stores.
- The only ext4 advantage (offline shrink) is irrelevant here.

Setup: `hcloud volume create --name psmdb-buildbarn-cas --size 500 --location hel1 --format xfs`, then `hcloud volume attach <id> <central-server>`, mount at `/var/lib/buildbarn`, point `storage-0` and `storage-1` at `/var/lib/buildbarn/storage-{cas,ac,fsac}-{0,1}` subdirectories, keep the compose files + scaler secrets on the same volume (under `/var/lib/buildbarn/config` and `/var/lib/buildbarn/secrets`) so re-attaching the volume to a fresh VM instantly restores the full setup.

Grow path: `hcloud volume resize <id> --size 1000 && ssh root@bb-psmdb 'xfs_growfs /var/lib/buildbarn'` — online, no downtime.

Monitoring: Prometheus alert on `node_filesystem_avail_bytes{mountpoint="/var/lib/buildbarn"} < 100GB`. When that fires: either resize volume online or trigger CAS GC (see §9 open questions — we still need to pick a GC policy).

The central node runs:

| Service | Port(s) | Purpose |
|---------|---------|---------|
| frontend | 8980 | Bazel client gRPC entry |
| storage-0, storage-1 | 8981 (via Envoy) | CAS/AC/FSAC sharded; data on attached volume |
| scheduler | 8982 (client), 8983 (worker), 8984 (buildQueueState), 7982 (admin HTML) | operation queue |
| browser | 7984 | UI |
| Envoy | 8981 | REAPI v2.0 proxy |
| **scaler (new)** | 9090 (own /metrics and pre-warm HTTP) | autoscale control loop |
| (optional, keep untouched) runner-fuse-ubuntu22-04 | — | pre-existing bb-deployments FUSE sample, not used by PSMDB |

### 5.2 Scaler daemon

A small Python daemon. Language choice: Python because (a) rest of the tooling ecosystem in Percona is Python-heavy, (b) `hcloud-python` SDK is mature, (c) BuildBarn proto files compile to Python via `grpcio-tools` in one step.

**Inputs:**

- Scheduler `BuildQueueState` gRPC at `localhost:8984` — structured, native protobuf API (see §6 for RPC list). This is **not Prometheus** and not `:7982/metrics` (which returns 404 because 7982 is the HTML admin UI, not a metrics endpoint).
- Hetzner API token (scoped, read+write for servers in a dedicated project).
- Declarative pool config file (see §5.3).

**Outputs:**

- Hetzner API calls (`server_create`, `server_delete`, `volume_attach` if needed) via `hcloud-python`.
- Structured logs (`spawned worker-bookworm-1703123456 in hel1`, `nbg1 capacity refused, trying fsn1`, `reaped worker-noble-1703122299 idle 6m`).
- Own Prometheus metrics endpoint at `:9090/metrics` exposing fleet size / decisions / errors.
- Pre-warm HTTP API on `:9090/prewarm` (see §5.5).

**Control loop (every `T_poll` seconds, default 30s):**

```python
# Pseudocode — real impl uses hcloud-python + grpc-python stubs.
queues = bqs.ListPlatformQueues()                           # gRPC :8984
workers = bqs.ListWorkers()

for pool_cfg in config.pools:
    q = match_queue(queues, pool_cfg.container_image_sha)   # by platform_properties
    queued      = q.queued_operations
    in_flight   = q.in_flight_operations
    pool_workers = [w for w in workers if w.platform == pool_cfg.platform]
    active_count = len([w for w in pool_workers if w.state == ACTIVE])
    draining     = [w for w in pool_workers if w.tag == "draining"]

    effective_capacity = active_count * pool_cfg.concurrency_per_node - in_flight

    # Scale up (respect hel1→nbg1→fsn1 try-chain)
    if queued > pool_cfg.scale_up_threshold and effective_capacity < queued:
        needed  = ceil((queued - effective_capacity) / pool_cfg.concurrency_per_node)
        allowed = min(needed,
                      pool_cfg.max_nodes - active_count,
                      config.global.max_total_nodes - total_active())
        for _ in range(allowed):
            spawn_with_region_fallback(pool_cfg)

    # Scale down
    for w in active_workers:
        if w.idle_since < now - pool_cfg.scale_down_idle_seconds and queued == 0:
            mark_draining(w)
    for w in draining:
        if w.in_flight == 0:
            destroy_via_hcloud(w)
```

**Scale-up decision threshold `scale_up_threshold`**: set higher than zero so trivial warm rebuilds don't spawn a VM. Rule of thumb: `scale_up_threshold = P.concurrency_per_node` (i.e. "spawn only if at least one full node's worth of work is queued"). For `cpx51` (24 concurrency) → threshold 24.

**Scale-up magnitude**: round up to fill the queue. `ceil(excess_queue / concurrency_per_node)`. Capped by `P.max_nodes` and global fleet cap.

**Region try-chain**: on Hetzner `resource_unavailable` (happens with `cpx62`/`ccx*` during EU peak), fall through hel1 → nbg1 → fsn1 in order. hel1 first because central lives there (lowest intra-AZ latency to CAS). This mirrors the pattern in `jenkins-pipelines/IaC/psmdb.cd/init.groovy.d/htz.cloud.groovy` (lines 151–169) which has one template per `(image, region, type)` and Jenkins picks the first available — we do the same logic programmatically in the scaler.

**Scale-down timing `scale_down_idle_seconds`**: the tension is:

- Too short → workers reaped between back-to-back dev builds → every build pays ~3 min cold start.
- Too long → idle Hetzner hours cost money.

Start with 600s (10 min). Hetzner bills **per hour, minimum**, so reaping more often than hourly is usually wasteful unless you hit ~30+ min idle.

**Spawn time budget**: from tests (manual VM creation on `cpx51`), boot + `apt install docker` + `docker pull runner-image` + `docker compose up` ≈ 90–120 s. The scaler should **not** spawn for a burst smaller than `spawn_time × concurrency` actions, because by the time the worker joins, the burst is over. Add a **pre-warm hint API** (§5.5) for known-large jobs and **snapshot-based fast boot** (§8 Phase 3) to shrink the budget to ~40 s.

### 5.3 Pool declarative config

Single YAML file (`ondemand-pools.yaml`) with one entry per variant in §11.1 of setup doc. Example:

```yaml
global:
  hcloud_project: psmdb-buildbarn                   # Hetzner project name
  hcloud_ssh_key_id: "htz.cd.bb-worker.key"         # public-key ID in Hetzner for ops SSH (see §5.10)
  hcloud_network_id: 11374636                       # psmdb.cd.percona.com private network
  scheduler_worker_grpc: 10.30.242.3:8983           # private IP workers dial to register
  scheduler_state_grpc:  localhost:8984             # scaler reads queue state from here
  registry: ghcr.io/vorsel/psmdb-buildbarn-runners  # dev phase — public, anonymous pull; production switches to ghcr.io/percona/...
  region_try_chain: [hel1, nbg1, fsn1]              # matches htz.cloud.groovy region rotation
  max_total_nodes: 30                               # hard cap across all pools (cost guard)
  max_total_vcpu: 240
  default_scale_down_idle_seconds: 600
  poll_interval_seconds: 30

pools:
  ubuntu-noble-x86_64:
    container_image_sha: "f1bd96104b3b8d33fff1500421917f3e15d9525795043e8d3f7f382e87c10002"
    runner_image: "psmdb-runner-ubuntu-noble-x86_64:20260421"
    hetzner_type: cpx51
    hetzner_image: "debian-13"                      # host OS, unrelated to runner distro; see note below
    concurrency_per_node: 24
    scale_up_threshold: 24
    min_nodes: 0
    max_nodes: 5
    labels:
      psmdb.pool: ubuntu-noble-x86_64
      psmdb.managed-by: bb-ondemand-scaler

  debian-bookworm-x86_64:
    container_image_sha: "d1df0fd76f9fdf28813fbe25dc9b989b5228f94cd37eae11fb194f67d3afdbbb"
    runner_image: "psmdb-runner-debian-bookworm-x86_64:20260421"
    hetzner_type: cpx51
    hetzner_image: "debian-13"                      # same host OS regardless of inner runner distro
    concurrency_per_node: 24
    scale_up_threshold: 24
    min_nodes: 0
    max_nodes: 5

  ubuntu-noble-aarch64:
    container_image_sha: "<tbd from MongoDB's map once arm variant exists>"
    runner_image: "psmdb-runner-ubuntu-noble-aarch64:20260421"
    hetzner_type: cax41
    hetzner_image: "debian-13"
    concurrency_per_node: 24
    scale_up_threshold: 24
    min_nodes: 0
    max_nodes: 3
```

Notes:

- **Host OS is decoupled from runner distro.** The host OS only needs to run Docker; the actual build environment is the runner image *inside* the container. Choose whichever recent, actively-maintained minimal image Hetzner has.
  - **Debian 13 (Trixie)** is already in Hetzner's cloud-image list and is the recommended default for the fleet — newer kernel than Bookworm, long support cycle, minimal footprint, good Docker support.
  - `ubuntu-24.04` is fine as a fallback.
  - **Ubuntu 26.04 LTS** (when released) will be another natural candidate — we can switch `hetzner_image` without touching runner images.
  - The old `htz.cloud.groovy` setup pins `deb12-x64` (Debian 12) via a pre-baked snapshot (`114690387`). That pattern is known-good but the host OS image itself is now a generation behind — we don't need to inherit that specific choice.
- `min_nodes: 0` at steady state; Jenkins jobs with predictable schedules can override via pre-warm API (§5.5).
- `container_image_sha` is the scheduler routing key (must match what PSMDB's Bazel client requests — it comes directly from `bazel/platforms/remote_execution_containers.bzl`).
- Once we bake our own Hetzner snapshots with Docker + pulled runner images pre-installed (§8 Phase 3), `hetzner_image` flips from `"debian-13"` (cloud-image) to a snapshot ID we produce (pattern mirrors `htz.cloud.groovy` lines 9–12 which pin specific IDs).

### 5.4 Worker bootstrap (cloud-init)

cloud-init YAML rendered from a template on spawn, carrying variables: scheduler address, pool name, runner image tag, container-image SHA, concurrency, ops SSH key.

The bootstrap reuses validated patterns from [`jenkins-pipelines/IaC/psmdb.cd/init.groovy.d/htz.cloud.groovy`](../psmdb.cd/init.groovy.d/htz.cloud.groovy) (`initMap['deb-docker']` at lines 79–134): `9.9.9.9/1.1.1.1` resolv.conf, `repo.ci.percona.com` in `/etc/hosts`, 32 GB swap, Docker GPG key + `docker-compose-plugin`, `--data-root=/mnt/docker`, `nofile=900000` ulimits, IPv6 disable, `tcp_fin_timeout=15`. These are already proven in the Percona Jenkins Hetzner fleet; the scaler shells out to the same block.

Example skeleton (simplified — real template is rendered from `bootstrap.j2`):

```yaml
#cloud-config
package_update: true
packages:
  - docker.io
  - docker-compose-plugin
write_files:
  - path: /opt/buildbarn/docker-compose.yml
    content: |
      services:
        runner-installer:
          image: ghcr.io/buildbarn/bb-runner-installer:<pinned>
          volumes:
            - bb:/bb
        worker:
          image: ghcr.io/buildbarn/bb-worker:<pinned>
          command: ["/config/worker.jsonnet"]
          volumes:
            - ./config:/config
            - ./volumes/worker:/worker
        runner:
          image: {{ registry }}/{{ runner_image }}
          command: ["sh", "-c", "while ! test -f /bb/installed; do sleep 1; done; exec /bb/bb_runner /config/runner.jsonnet"]
          volumes:
            - ./config:/config
            - bb:/bb
            - ./volumes/worker:/worker
          depends_on: [runner-installer]
      volumes:
        bb:
  - path: /opt/buildbarn/config/worker.jsonnet
    content: |
      {{ worker_jsonnet_rendered_with_pool_sha_and_concurrency }}
  - path: /opt/buildbarn/config/runner.jsonnet
    content: |
      { buildDirectoryPath: '/worker/build',
        grpcServers: [{ listenPaths: ['/worker/runner'], authenticationPolicy: { allow: {} } }],
        global: { ... } }
  - path: /opt/buildbarn/enable-swap.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      fallocate -l 32G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
      echo "/swapfile none swap sw 0 0" >> /etc/fstab
runcmd:
  - /opt/buildbarn/enable-swap.sh
  - cd /opt/buildbarn && docker compose pull && docker compose up -d
  - systemctl enable docker
final_message: "bb worker for pool {{ pool_name }} ready"
```

Bootstrap timing budget:

| Phase | Seconds (cpx51) |
|-------|-----------------|
| Hetzner VM provision (API call → running) | 20–40 |
| cloud-init: apt update + install docker | 30–60 |
| `docker pull` runner image from ghcr.io (~500 MB) | 30–60 |
| `docker compose up` + runner-installer sync | 10–20 |
| bb_worker registered with scheduler | 5–15 |
| **Total to usable** | **~90–180 s** |

Pre-bake into a Hetzner snapshot once cloud-init is stable, dropping boot time to ~40–60 s (see §8 Phase 3).

**Private-IP-only networking**: the VM is created with `networks=[hcloud_network_id]` and `start_after_create=true` but **without** `public_net.ipv4=True`. Outbound internet (needed for `apt-get update`, `docker pull ghcr.io`) still works via Hetzner's default NAT from the private network's subnet gateway. Workers dial the scheduler at its **private** IP (`10.30.242.3:8983`) — no public-IP hop. This eliminates public-IP bandwidth costs for CAS traffic (hundreds of GB per full matrix).

### 5.5 Pre-warm API

The scaler exposes `POST /prewarm` on its admin endpoint:

```json
{ "pool": "ubuntu-noble-x86_64", "nodes": 2, "ttl_seconds": 3600 }
```

Signal from Jenkins release jobs: "I'm about to start a full matrix, keep N nodes of pool X alive for TTL". Scaler tracks these reservations, skips scale-down for them, and marks their eligibility to reap when TTL expires.

This is the **cheap fix for cold-start latency** — without it, each release job's first 90–180 s is spent waiting for a worker. With pre-warm triggered 3 min before Jenkins spawns the Bazel build, the pool is ready.

### 5.6 State & coordination

State options (in order of preference):

**(a) Hetzner tags on the VM itself** — zero external state, scaler re-discovers on startup.

```
server labels:
  psmdb.pool = ubuntu-noble-x86_64
  psmdb.managed-by = bb-ondemand-scaler
  psmdb.spawned-at = 1703122000
  psmdb.last-seen-idle-at = 1703125600     # updated by scaler
  psmdb.state = active | draining | reaping
```

Scaler enumerates `hcloud server list --selector psmdb.managed-by=bb-ondemand-scaler` each loop. Survives scaler restarts, replaces need for a database.

**(b) SQLite file on the central node** — only if (a) becomes too slow/racy. For <100 workers enumerating tags is fine.

**(c) External (etcd / Redis)** — explicit non-goal for phase 1 to keep moving parts down.

### 5.7 Drain & destroy

`bb_worker` has no first-class "drain" SIGTERM handler that I've seen in the BuildBarn Slack archive, but:

1. **Soft drain**: stop sending new operations to it by de-registering platform properties. Achievable by killing `bb_worker` process — the worker stops pulling new work. Actions mid-flight complete against the runner if we don't kill that.
2. **Hard drain**: `docker compose down` the whole stack — in-flight actions are cancelled, client retries on another worker. Safe because actions are idempotent by design.

Proposed approach for phase 1: **hard drain**.
Phase 2 (if lost work becomes a problem): implement soft drain by SIGTERMing `bb_worker` first, waiting `in_flight == 0` (query via worker's `:80` diagnostics HTTP), then destroy VM.

In either case: **wait for the `docker stop` to complete before calling `hcloud server delete`** so the runner has a chance to upload final action outputs to CAS.

### 5.8 Safety rails

| Rail | Default | Purpose |
|------|---------|---------|
| `max_total_nodes` | 30 | hard cap across all pools |
| `max_total_vcpu` | 240 | redundant cap by CPU (catch "accidentally spawned cpx51 instead of cpx11") |
| `max_nodes_per_pool` | 5 | per-pool cap |
| `spawn_cooldown_seconds` | 60 | don't spawn two for same pool within 60s (prevents thrashing on metric spikes) |
| `destroy_cooldown_seconds` | 120 | similar for scale-down |
| `max_cost_per_hour` | €5 | sum of current VM hourly rates; scaler halts spawns if exceeded |
| Stale-VM cleaner | runs every 1h | kills any tagged VM older than 24h regardless of activity (emergency leak protection) |

All rails configurable via `ondemand-pools.yaml` `global:` section.

### 5.9 Observability

Scaler exposes its own `/metrics`:

```
bb_ondemand_scaler_pool_queued{pool="..."}                  gauge
bb_ondemand_scaler_pool_active_workers{pool="..."}          gauge
bb_ondemand_scaler_pool_in_flight{pool="..."}               gauge
bb_ondemand_scaler_decisions_total{action="spawn|reap",pool="..."}  counter
bb_ondemand_scaler_hcloud_api_errors_total{operation="..."} counter
bb_ondemand_scaler_estimated_hourly_cost_eur                gauge
```

Plus a small HTML dashboard on `:9090/` for human inspection — list of current fleet, last N decisions, trailing cost.

### 5.10 SSH access to private-only workers

Workers have no public IP, so direct `ssh root@<public>` is not available. Two access paths:

**Ops SSH (for debugging)** — bastion via central:

```bash
ssh -J root@barn-psmdb root@10.30.242.XX   # jump through central
```

This works out of the box because central has a public IP and a private IP in the same `11374636 psmdb.cd.percona.com` network as workers. Only access prerequisite: your public key is in central's `/root/.ssh/authorized_keys`.

**Dedicated SSH key for workers**: `htz.cd.bb-worker.key` (parallel to the existing `htz.cd.key` used by `htz.cloud.groovy`). The public half is uploaded to the Hetzner project as an SSH key resource and referenced in `ondemand-pools.yaml` `global.hcloud_ssh_key_id`; cloud-init auto-injects it into `/root/.ssh/authorized_keys` via `hcloud server create --ssh-key <id>`. The private half lives on central under `/opt/buildbarn/scaler/secrets/htz.cd.bb-worker.key` (0600 root) and in Jenkins credential store for pipeline jobs that need to reach a worker directly.

Why a separate key from `htz.cd.key`: different trust boundary (bb-worker is a disposable, unauthenticated-docker-pull-from-internet host; `htz.cd.key` unlocks Jenkins runners with repo-write tokens). Compromising the bb-worker key should not compromise the Jenkins worker fleet.

For phase 3 consider Tailscale overlay — gives `ssh worker-pool-bookworm-1` by short name and removes the bastion hop, but adds one more sidecar (`tailscaled`) to each VM.

## 6. How the scaler reads scheduler state

**Not via `/metrics` on port 7982.** That port serves the HTML admin UI (`adminHttpServers`), which has no `/metrics` path — hitting `http://65.108.253.73:7982/metrics` returns `404 page not found`, which is correct behaviour for that endpoint.

**Primary: `BuildQueueState` gRPC on port `8984`.** BuildBarn's scheduler exposes a structured, versioned protobuf service intended for programmatic state inspection — this is what `bb-browser` and the HTML admin UI themselves call internally. In the upstream [`scheduler.jsonnet`](https://raw.githubusercontent.com/buildbarn/bb-deployments/master/docker-compose/config/scheduler.jsonnet) it's declared as:

```jsonnet
buildQueueStateGrpcServers: [{ listenAddresses: [':8984'], authenticationPolicy: { allow: {} } }],
```

Port 8984 is already published in the upstream [`docker-compose.yml`](https://raw.githubusercontent.com/buildbarn/bb-deployments/master/docker-compose/docker-compose.yml). Relevant RPCs (from `pkg/proto/buildqueuestate/build_queue_state.proto`):

| RPC | Purpose for the scaler |
|-----|------------------------|
| `ListPlatformQueues` | returns every platform pool the scheduler knows about, with `(queued, in-flight, idle workers)` counters. **This is the main input for scale-up decisions.** |
| `ListQueuedOperations` | per-pool queued operations (when finer granularity needed, e.g. for priority-aware scheduling hooks) |
| `ListWorkers` | enumerates active workers per queue with their `worker_id`, `last_seen`, and current operation — used for scale-down eligibility ("worker idle for > 10 min") |
| `ListOperationState` | deep inspection for individual ops (debug only) |

Implementation: scaler imports the proto with `grpcio-tools`, calls `ListPlatformQueues()` every `poll_interval_seconds`, matches each queue's platform-property set to the config's `container_image_sha`, computes decisions from the counters.

**Fallback: Prometheus `/metrics`.** If for any reason the proto API proves unreliable (version drift, etc.), we can expose the scheduler's built-in Prometheus endpoint. In bb-deployments' `common.libsonnet` it's pre-configured but only bound to `:80` **inside the scheduler container** and not published. To use it, add to the scheduler service in `docker-compose.yml`:

```yaml
scheduler:
  ports:
    - "9982:80"   # expose global.diagnosticsHttpServer
```

Then `http://localhost:9982/metrics` returns Prometheus text format with `buildbarn_builder_build_queue_operations_queued_total{platform_queue="..."}` and similar. Label names are undocumented but stable across minor versions.

No BuildBarn fork, no protocol hack, no custom gateway needed — the pattern of "wrap an unstable/opaque upstream with our own clean API" (used for REAPI v2.0 via Envoy in the setup doc §7) is **not required here**, because the scheduler already has a clean versioned proto.

## 7. Registry prerequisite (blocks everything else)

The current `docker save | scp | docker load` distribution works for 1 variant × 4 static nodes. It does not work for ondemand because:

- New VM spawns every time a build needs capacity. It must pull the image via its own network — can't block waiting for an operator to scp.
- 11+ variants × weekly rebuild cadence × arbitrary number of short-lived VMs → registry is the only viable distribution.

**Registry: `ghcr.io` with public images.** Two-phase migration:

- **Development phase (now):** `ghcr.io/vorsel/psmdb-buildbarn-runners/*` under the project owner's personal GitHub account. Workflow runs in `vorsel/jenkins-pipelines` (personal fork). Unblocks iteration without waiting on Percona org policy/ACL approvals.
- **Production migration (final step before ondemand goes into Percona CI):** switch to `ghcr.io/percona/psmdb-buildbarn-runners/*`. Requires: (a) Percona GitHub org approval for package creation, (b) re-run of the GHA workflow inside `percona/jenkins-pipelines` to populate the org-owned registry, (c) single-line flip in `ondemand-pools.yaml`: `registry: ghcr.io/percona/psmdb-buildbarn-runners`. No code changes beyond that. Optionally keep `vorsel/*` as a temporary mirror during cut-over; archive old packages via ghcr.io UI after.

Both phases use identical mechanics — the below is written for the dev-phase `vorsel` registry and trivially re-targets to `percona` later.

**Zero-secret push via GitHub Actions.** A workflow file (`.github/workflows/build-runners.yml` in `vorsel/jenkins-pipelines` during dev, promoted to `percona/jenkins-pipelines` for production) builds each runner image and pushes to ghcr.io. Authentication uses the auto-provisioned `GITHUB_TOKEN` (no PAT stored anywhere):

```yaml
name: build-runners
on:
  push:
    paths: [ 'jenkins-pipelines/IaC/buildbarn/runners/**' ]
  schedule:
    - cron: '0 3 * * 0'     # weekly rebuild to catch upstream package updates
permissions:
  contents: read
  packages: write            # scope needed to push to ghcr.io/<org>
jobs:
  build:
    strategy:
      matrix:
        variant: [ubuntu-noble-x86_64, debian-bookworm-x86_64, ...]
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}   # auto-generated per run
      - uses: docker/build-push-action@v5
        with:
          context: jenkins-pipelines/IaC/buildbarn/runners/${{ matrix.variant }}
          push: true
          tags: |
            ghcr.io/vorsel/psmdb-buildbarn-runners/${{ matrix.variant }}:${{ github.sha }}
            ghcr.io/vorsel/psmdb-buildbarn-runners/${{ matrix.variant }}:latest
```

(When migrating to production: replace `vorsel` → `percona` in the `tags:` block — one edit, same workflow.)

**Zero-credential pull on workers.** Images are marked public in ghcr.io UI (Settings → Packages → change visibility). Cloud-init on worker VMs runs `docker pull ghcr.io/vorsel/psmdb-buildbarn-runners/<variant>:latest` (or `ghcr.io/percona/...` in production) without any `docker login` — anonymous pull works for public packages.

**If policy ever demands private images**: mark packages private in ghcr.io, issue a long-lived fine-grained PAT scoped `packages:read`, inject via Hetzner `user_data` (first-boot only, pull, then remove the token from disk). Not needed for phase 1 since `psmdb_builder.sh` and its derived images contain only public OSS content.

Alternatives considered and rejected:

| Option | Rejected because |
|--------|------------------|
| `quay.io/percona/psmdb-buildbarn-runners` | Paid tier for storage at our expected volume (~15 GB × 11 variants × weekly rebuild) |
| Private Percona Harbor/Nexus | No existing host in Percona IaC; ops overhead for a single artifact store |
| `hub.docker.com/u/perconalab` | Rate limits (100 pulls / 6h for unauth, 200 for auth) hurt when 30 VMs boot in parallel |

## 8. Step-by-step implementation roadmap

In strict dependency order — each step unblocks the next.

> **Throughout every phase: the existing `bb-psmdb` / `barn-psmdb-worker-1` / `barn-psmdb-worker-2` / `psmdb-mongot` fleet is NEVER modified.** Every step below creates new Hetzner resources only. See §2.1.

### Phase 0 — Prerequisites (all-new resources)

1. **Set up registry** (see §7). Create the GHA workflow in `vorsel/jenkins-pipelines` (personal fork) that builds runners and pushes to `ghcr.io/vorsel/psmdb-buildbarn-runners/*`. Mark packages public in ghcr.io UI after first push. No PATs or repo-stored credentials — Actions' `GITHUB_TOKEN` with `packages:write` scope is sufficient. Migration to `ghcr.io/percona/...` happens in the final production step, one-line change in `ondemand-pools.yaml`.
2. **Build and push `ubuntu-noble-x86_64` and `debian-bookworm-x86_64` runner images** via the GHA workflow. Validate end-to-end: pick any fresh Hetzner VM (throwaway), `docker pull ghcr.io/vorsel/psmdb-buildbarn-runners/ubuntu-noble-x86_64:latest`, `docker run` it, confirm `psmdb_builder.sh install_deps` artefacts are in place. **Do not** re-deploy the existing `bb-psmdb` / worker-1 / worker-2 / mongot containers to use this registry; they keep running their current `docker save/load` tarball images untouched.
3. **Create the NEW central VM and CAS volume.** Parallel to the existing `bb-psmdb`, we spin up a sibling host dedicated to the ondemand experiment:
   ```bash
   # new volume for ondemand CAS (500 GB xfs)
   hcloud volume create --name psmdb-buildbarn-cas-ondemand --size 500 --location hel1 --format xfs

   # new central VM — does NOT replace bb-psmdb, lives alongside it
   hcloud server create \
       --name bb-psmdb-ondemand \
       --type cpx42 \
       --image debian-13 \
       --location hel1 \
       --ssh-key htz.cd.bb-worker.key \
       --network 11374636

   hcloud volume attach <volume-id> bb-psmdb-ondemand

   # on bb-psmdb-ondemand:
   mkdir -p /var/lib/buildbarn
   echo "/dev/disk/by-id/scsi-0HC_Volume_<id>  /var/lib/buildbarn  xfs  defaults,nofail,discard,noatime  0 0" >> /etc/fstab
   mount -a
   ```
   Lay out on the volume:
   - `/var/lib/buildbarn/storage-{cas,ac,fsac}-{0,1}/` — storage shard data
   - `/var/lib/buildbarn/config/` — `docker-compose.yml`, `frontend.jsonnet`, `storage.jsonnet`, `scheduler.jsonnet`, `browser.jsonnet`
   - `/var/lib/buildbarn/secrets/` — scaler Hetzner token, `htz.cd.bb-worker.key` private half (when Phase 2 arrives)

   This is a fresh install of BuildBarn on the new host — empty CAS, no leftover state. The old `bb-psmdb` keeps doing its job on its own box, its own volume, its own Docker containers.

### Phase 1 — Manual-spawn prototype (ondemand workers against the NEW central)

4. **Manual Hetzner VM spawn script** (`scripts/spawn-worker.sh`): `./spawn-worker.sh ubuntu-noble-x86_64` creates a new `cpx51` in `hel1`, runs cloud-init (§5.4), confirms worker joined `bb-psmdb-ondemand`'s scheduler (NOT the old `bb-psmdb`). No autoscale logic yet — operator-triggered.

   Borrow heavily from [`jenkins-pipelines/IaC/psmdb.cd/init.groovy.d/htz.cloud.groovy`](../psmdb.cd/init.groovy.d/htz.cloud.groovy):
   - **Region try-chain** `hel1 → nbg1 → fsn1` (lines 151–169 pattern — one template per `(image, region, type)`, walk until one succeeds with HTTP 201 instead of `409 resource_unavailable`).
   - **Host-OS image choice**: `htz.cloud.groovy` uses `114690387 deb12-x64` / `114690389 deb12-aarch64` pre-baked snapshots (Debian 12). For the BuildBarn fleet prefer something newer — **Debian 13 (Trixie)** is the recommended default (available as `debian-13` cloud-image on Hetzner); `ubuntu-24.04` or the upcoming Ubuntu 26.04 LTS are fine alternatives. The host OS is fully decoupled from the runner distro inside the container (see §5.3 notes). In phase 3 we bake our own PSMDB-specific snapshot on top of whichever base we picked.
   - **Init-script pattern** (`initMap['deb-docker']`, lines 79–134): swap, Docker GPG+apt repo, `--data-root=/mnt/docker`, ulimits, DNS pinning, `repo.ci.percona.com` host entry. All of this goes into cloud-init verbatim.
   - **Network ID**: worker templates in `htz.cloud.groovy` use `networkMap['percona-vpc-eu'] = '10442325'`. **Do not reuse** that one for BuildBarn — use the separate `11374636 psmdb.cd.percona.com` network (shared with the old fleet is fine; they don't collide because workers dial the new `bb-psmdb-ondemand` private IP, not `bb-psmdb`). Optionally create a dedicated network later if stricter isolation is wanted.
   - **SSH pattern**: `htz.cloud.groovy` uses `SshConnectorAsRoot("htz.cd.key")`. We create a parallel `htz.cd.bb-worker.key` for the ondemand bb-worker fleet (see §5.10).

5. **Run a full `install-dist-test` against `bb-psmdb-ondemand`**: from a developer box, set `.bazelrc` to point `--remote_executor` at the new central, spawn 3×ubuntu-noble workers manually, run the build. Wall-time should match the current permanent fleet's warm build. Proves the cloud-init + registry + auto-join loop end-to-end on fresh infrastructure, with zero impact on the existing fleet.
6. **Keep the existing fleet untouched.** No retirement, no re-deploy. The old `bb-psmdb` + `worker-1` + `worker-2` + `mongot` continue serving whatever Bazel clients are pointed at them. Cut-over (if/when we decide) is a separate, explicit step: one client-side `.bazelrc` change.

### Phase 2 — Scaler MVP (still parallel, old fleet untouched)

7. **Implement scaler daemon** (§5.2) with only scale-up logic, no scale-down. `hcloud-python` + `grpcio-tools`-generated `BuildQueueState` client, poll loop every 30s. Configuration: 2 pools (noble + bookworm). Scaler talks to `bb-psmdb-ondemand`'s scheduler gRPC at `:8984`. Tests: artificial load (`--jobs=96` build from an empty cache) triggers spawn.
8. **Add scale-down logic** with `scale_down_idle_seconds = 600`. Tests: run a build, verify workers destroyed within 10 min of finish.
9. **Add safety rails** (§5.8). Tests: force-trigger quota exhaustion, confirm scaler halts gracefully.
10. **Deploy scaler as docker service on `bb-psmdb-ondemand`.** Logs go to journald; Prometheus scraping of scaler's own `/metrics` added.

### Phase 3 — Production hardening

**11. Pre-warm API** (§5.5).
The scaler exposes `POST /prewarm {"pool": "...", "nodes": N, "ttl_seconds": T}` on its `:9090` HTTP. Jenkins release-matrix jobs call it **3 minutes before** invoking Bazel so the cold-start latency is absorbed out-of-band. Without this, the first 90–180 s of every release run is spent waiting for workers to come up — paid in wall-time on every pool.

Minimal Jenkins integration (one line in the job's pre-build step):

```bash
curl -X POST http://bb-psmdb-ondemand:9090/prewarm \
     -H 'Content-Type: application/json' \
     -d '{"pool":"ubuntu-noble-x86_64","nodes":3,"ttl_seconds":3600}'
```

Scaler keeps the reservation for `ttl_seconds` — skips scale-down for those nodes even if they sit idle (prevents races where the Jenkins job starts 90s after `/prewarm` but the scaler reaps at 60s because queue happens to be empty). Reservations expire automatically; no cleanup API needed.

**12. Observability dashboard** (§5.9) — minimal HTML + metrics scrape to Percona's existing Prometheus if available.

**13. Snapshot-based fast boot** — bake a Hetzner snapshot with Docker + pre-pulled `bb-worker`, `bb-runner-installer`, and the pool-specific runner image, so cold boot does not do `apt-get install docker` or `docker pull` at spawn time.

Mechanics:

1. Spawn a `cpx51` from stock `ubuntu-24.04` cloud-image.
2. Run cloud-init that ends with `docker pull ghcr.io/vorsel/psmdb-buildbarn-runners/ubuntu-noble-x86_64:latest && docker pull ghcr.io/buildbarn/bb-worker:PINNED && docker pull ghcr.io/buildbarn/bb-runner-installer:PINNED && systemctl stop docker && sync` (replace `vorsel` with `percona` post-migration).
3. Call `hcloud server create-image --type=snapshot --description=psmdb-runner-noble-YYYYMMDD`.
4. Record the returned snapshot ID (e.g. `114690400`) in `ondemand-pools.yaml`:
   ```yaml
   ubuntu-noble-x86_64:
     hetzner_image: "114690400"    # pre-baked
   ```
5. Scaler uses that ID for subsequent `server_create` calls. Spawn path becomes: boot from snapshot (~20 s) → `docker compose up` (~10 s) → worker registers (~10 s). Total ~40 s vs ~120 s.

Rebuild cadence: one snapshot per `(pool × rebuild_event)`. The GHA workflow from §7 triggers a follow-up "snapshot-bake" job that spawns a short-lived VM, runs the pull sequence, takes a snapshot, deletes old snapshots for that pool. Weekly cron keeps them fresh.

Trade-off: each snapshot costs Hetzner storage (~€0.01 per GB-month). A 160 GB snapshot × 11 runner images = 11 × €1.60 = ~€18/month. Amortises quickly against saved spawn time during matrix runs.

**14. aarch64 support** — add ARM variant pools. `cax41` (16c / 32 GB ARM, shared) is the default type mirroring `cpx51` for x86. The `htz.cloud.groovy` file already validates `cax31/cax41` in all three regions (lines 155–165), so the Hetzner side is known-good.

Prerequisites to verify before committing:

- PSMDB's [`bazel/platforms/remote_execution_containers.bzl`](../../../percona-server-mongodb/bazel/platforms/remote_execution_containers.bzl) has entries for the target aarch64 distro. Some distros (OL8/OL9) may have empty or unverified aarch64 SHAs — check with `grep -A3 aarch64 remote_execution_containers.bzl`. If missing, either contribute upstream to MongoDB's Bazel files or pin our own fork of that map.
- `psmdb_builder.sh install_deps()` works end-to-end on the target aarch64 distro image (same empirical validation we did for `debian-bookworm-x86_64` in §9.7 of setup doc, repeated per aarch64 variant).
- GHA workflow from §7 has `matrix.variant` entries for aarch64 and runs on `ubuntu-24.04-arm` runners (GitHub offers them as of 2025).

### Phase 4 — Full matrix + production cut-over

15. **Build remaining 9 runner variants** (ubuntu-jammy, ol8/9, al2/2023, debian bookworm tarball variants, all aarch64 counterparts). Push to registry.
16. **Add all 11 pool entries to `ondemand-pools.yaml`** (one per row in §3.1 table).
17. **Run one full release matrix** via Jenkins using ondemand workers against `bb-psmdb-ondemand`. Measure wall-time, worker fleet size peaks, cost. Old fleet (`bb-psmdb` + its 3 workers) still untouched — a single safety net if ondemand matrix run fails.
18. **Tune thresholds** based on real matrix data — likely `min_nodes` for hot variants like `ubuntu-noble-x86_64` goes from 0 to 1 if dev-build cadence is frequent enough that startup latency becomes annoying.
19. **Production cut-over decision** (explicit, human-in-the-loop):
    - If ondemand wall-time and reliability match or beat the old fleet over N real builds, point Jenkins/developers' `.bazelrc` at `bb-psmdb-ondemand`.
    - Let the old fleet run in parallel for one more week for safety (dual-read: some dev builds still land on old, still work).
    - Only then retire the old `bb-psmdb` + `worker-1` + `worker-2` + `mongot` (snapshot their disks first for rollback safety).
    - Rename `bb-psmdb-ondemand` → `bb-psmdb` and `psmdb-buildbarn-cas-ondemand` → `psmdb-buildbarn-cas` (Hetzner supports rename).
20. **Migrate registry to Percona org**: push images to `ghcr.io/percona/psmdb-buildbarn-runners/*`, flip one line in `ondemand-pools.yaml`.

## 9. Open questions / risks

- **`BuildQueueState` proto stability.** The proto is part of `bb-remote-execution`'s public API but not version-SLA'd — upgrades could rename fields. Mitigation: pin the BuildBarn scheduler image digest in `docker-compose.yml`; add integration test that calls `ListPlatformQueues()` on scheduler startup and fails CI if the response doesn't match expected shape.
- **CAS garbage collection.** bb-storage does not auto-GC. At ~30 workers doing cold builds, the 100 GB volume fills in weeks. Mitigation options: (a) periodic full wipe of CAS on schedule (loses warm-cache advantage after each wipe — bad for release cadence), (b) size-based LRU eviction via Redis backend (bb-storage supports it but adds a Redis service), (c) simply resize volume (Hetzner allows to 10 TB online) and accept forever-growing footprint until cost becomes uncomfortable. Recommend (c) until cost hits a pain threshold, then (b).
- **Action cache invalidation on runner image rebuild.** If weekly rebuild produces a new SHA for `psmdb-runner-ubuntu-noble-x86_64`, all its AC entries become stale (different `container-image` property → different action digest). First build after rebuild pays full cold-run cost. **This is intentional** (catches drift) but means release runs the day after a rebuild are slow — schedule rebuilds on weekends, not mid-week.
- **Hetzner API rate limits.** Default limit ~100 req/s; scaler polls every 30s → safe. But during a massive matrix spawn (11 pools × 3 VMs each = 33 `server create` calls in quick succession), might hit short-term caps. Mitigation: serialise spawn calls with a 2–3s jitter.
- **Per-pool cost attribution** not built-in. Hetzner doesn't tag invoice lines by our labels. For internal accounting, the scaler should emit `bb_ondemand_scaler_estimated_hourly_cost_eur` broken down by pool, and a nightly job logs cumulative costs.
- **Private networking between ondemand workers and central** — Hetzner private network adds latency-free and bandwidth-free transfers. Must create one "psmdb-buildbarn" private network and attach every spawned VM to it (cloud-init can do this given network_id). Skipping this forces public-IP CAS transfers, which both slows down builds and burns bandwidth quota.
- **Swap provisioning at boot**: Hetzner cpx51 comes with 240 GB SSD; 32 GB swap leaves plenty of room. cax41 has 320 GB. Both fine.
- **What if scaler crashes mid-spawn?** VM is created but no config file references it, no record. Mitigation: every spawn sets the tag `psmdb.state=spawning` **before** API call; on scaler restart, it finds `spawning` VMs older than 10 min and either completes bootstrap (if VM is live) or destroys (if broken).
- **Multi-pool on one VM for static central worker.** If the central node keeps a small worker for overflow (§5.1), its static multi-pool config (§9.7 of setup doc) remains valid — ondemand design does not touch it.

## 10. Alternatives considered

| Alternative | Why rejected |
|-------------|--------------|
| Kubernetes + HPA + custom metrics adapter | Too much infra for 4–30 VMs; k8s cluster adds more complexity than it saves |
| BuildBarn's own `bb-autoscaler` (third-party community project) | Not officially supported; specific to AWS/GCP patterns; Python wrapper is a week of work vs adopting + debugging a third-party binary |
| Always-on fleet sized for full matrix | Costs ~5× more than ondemand for same peak throughput; wasteful during the 80% idle hours |
| One large dedicated node (ccx53/ccx63) with high concurrency | Blocked by 8-dedicated-CPU tariff cap. Even if unblocked, single point of failure; elastic fan-out is more robust |
| Multi-pool on every ondemand worker (all workers serve all pools) | Doesn't save money (still need enough capacity for peak), and pulling all 11 runner images per VM boot would take 30+ min. Single-pool VMs are simpler |
| Terraform + GitHub Actions scheduled workflow | Requires operator to plan scale events; defeats the purpose of "scale on queue depth" |

## 11. Minimal viable cost model

Back-of-envelope for current Percona usage pattern, Hetzner list prices (EUR, rounded):

| Scenario | Fleet | Cost |
|----------|-------|------|
| **Current (unchanged during dev)** — old fleet | `bb-psmdb` (cpx62) + 3 workers + mongot | ~€200/month |
| **Dev overhead — parallel ondemand setup** (Phase 0–3) | `bb-psmdb-ondemand` cpx42 + 500 GB xfs volume | +€17 + €20 = **+~€37/month** added on top of old fleet during dev |
| **Total during dev phase** (parallel running) | old fleet + new central (no workers idle) | **~€237/month** — temporary premium to de-risk migration |
| **Post-cut-over** (old fleet retired, step 19) | 1 × `cpx42` ondemand central + 500 GB volume + ephemeral workers | ~€37/month + per-build costs |
| Post-cut-over, if later upgraded to dedicated central | 1 × `ccx23` + 500 GB volume | ~€45/month |
| One dev build (1 h wall time, noble, cold-ish) | central + 3 × `cpx51` for 1h | ~€0.33 per build |
| One dev build (1 h wall time, warm via AC) | central + 1 × `cpx51` for 1h | ~€0.11 per build |
| Full matrix run (2.5 h, 11 pools × ~2 VMs peak avg = ~22 worker-hours across `cpx51`/`cax41`) | central + avg ~9 VMs concurrently | ~€3–4 per matrix run |
| Snapshot storage (phase 3, optional) | ~11 variants × 160 GB | ~€18/month |

**Net savings post-cut-over**: from ~€200/month (old permanent fleet) to ~€37/month steady + ~€5 per matrix run + per-build dev costs. At Percona's measured pattern (~20 dev builds + 2 full matrix runs per week), that's roughly **~€50–55/month total** vs **~€200** today — a **~4× reduction**, plus elimination of operator toil.

**Dev-phase premium** is ~€37/month on top of the current ~€200 for however long Phases 0–3 take. This is the explicit cost of not touching prod — a ~18% temporary overhead for zero rollback risk. The premium disappears at step 19 when the old fleet is retired.

Caveats:

- Hetzner **bills per hour, minimum** — a 5-minute worker still costs one hour. Scale-down timing (§5.2) should batch reaps to minimise this.
- **Bandwidth cost**: private-network traffic between central and workers is free; the concern is `docker pull` from ghcr.io on spawn, but ghcr.io has no egress cost on Hetzner's side.
- **Volume cost scales with size, not usage** — 500 GB = €20/month regardless of how full; resizing up is cheap, resizing down is not supported (would require create-new/migrate/delete).
- **CAS GC is still an open question** (§9). If the volume fills faster than expected, either grow it (`hcloud volume resize`) or add a GC strategy. €20/month covers 500 GB; going to 1 TB is €40.

## 12. Next concrete actions

The existing prod fleet (`bb-psmdb` + 3 workers + mongot) stays running and untouched. Every step below adds new Hetzner resources only.

**Immediate (Phase 0):**

1. Create `.github/workflows/build-runners.yml` in `vorsel/jenkins-pipelines`, push first runner images to `ghcr.io/vorsel/psmdb-buildbarn-runners/ubuntu-noble-x86_64:<sha>` and `:latest`. Mark packages public.
2. Validate pull path on a throwaway Hetzner VM: `docker pull ghcr.io/vorsel/...` → `docker run` → confirm `psmdb_builder.sh` artefacts present.
3. Create `psmdb-buildbarn-cas-ondemand` 500 GB xfs volume + new `bb-psmdb-ondemand` cpx42 host in hel1. Install BuildBarn control-plane (scheduler, 2 storage shards, frontend, browser, Envoy REAPI proxy) on the new host, all state on volume at `/var/lib/buildbarn`.

**Then (Phase 1):**

4. Write `scripts/spawn-worker.sh` — manual-spawn prototype, one evening of work, target: first validated worker that joins `bb-psmdb-ondemand` and picks up a test build.
5. Run a cold `install-dist-test` from a developer box pointed at `bb-psmdb-ondemand`. Compare wall-time to existing-fleet warm build.

**Then (Phase 2):**

6. Write `ondemand-pools.yaml` schema and initial config for 2 pools (noble + bookworm).
7. Prototype scaler daemon against a hand-run test queue (generate fake load via `bazel build --noremote_accept_cached`).
8. Pair-review the scaler code with one other engineer before it gets production authority to spawn/destroy VMs.

No step here touches the existing fleet. Cut-over is an explicit, separate decision (Phase 4 step 19).
