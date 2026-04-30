# BuildBarn — Build Observability via bb-portal

> Status: **IN PROGRESS** — Steps 1, 2, 3, 5, 6 DONE (jenkins-pipelines side
> wired up: compose services, jsonnet, dex client, envoy listener, bake_env,
> smoke probes, runbook). **Step 4 pending** in `percona-server-mongodb` —
> needs `--bes_backend` + `--bes_results_url` + `--bes_header` added to
> `.bazelrc.psmdb`'s `psmdb_buildfarm` config block, plus the matching
> `wrapper_hook.py` extension if Bazel doesn't auto-forward the `--remote_header`
> token to BES (verify on first deploy).
> Last update: 2026-04-29.
> Tracking: TBD (new Jira PSMDB-* ticket to be created when impl begins).
> Working domain: `bb-psmdb.ddns.net` (No-IP DDNS, same as the rest of the
> BuildBarn stack — see [`buildbarn-auth-tls-plan.md`](./buildbarn-auth-tls-plan.md)
> for the auth/TLS posture this plan inherits).
> Related: this plan slots **after**
> [`buildbarn-auth-tls-plan.md`](./buildbarn-auth-tls-plan.md) §5 — the
> portal sits behind the same Dex OIDC IdP as bb-browser and bb-scheduler.
> Sibling docs: [`buildbarn-remote-execution-setup.md`](./buildbarn-remote-execution-setup.md), [`buildbarn-ondemand-scaler.md`](./buildbarn-ondemand-scaler.md), [`ondemand/README.md`](./ondemand/README.md).

## Why

`bb-scheduler-admin` (`:7982`) is a **runtime** view: it shows operations
that are queued, executing, or have completed within the last
`OperationWithNoWaitersTimeout` window (currently 1 minute, baked into
`bb-remote-execution`'s `NewInMemoryBuildQueue`). Once a Bazel client
disconnects and 60 s elapse, the operation is gone from scheduler memory.

Today this means a developer / CI engineer can:

* see what is running NOW (`/operations?filter_stage=UNKNOWN`)
* drill into an action by digest in `bb-browser` (`:7984`) — but ONLY
  if they have the digest from a Bazel error message
* nothing else — no historical "what happened in this build invocation"
* no per-action timeline, no critical-path analysis, no flake analysis

For PSMDB this hits the moment a build fails on Jenkins or a developer
laptop and we want to investigate post-mortem 30 minutes later. The
information is already gone from `:7982`.

The fix that bb-storage / bb-remote-execution upstream points at is
[**bb-portal**](https://github.com/buildbarn/bb-portal): a separate
HTTP service that ingests Bazel's Build Event Stream (BES), persists
invocation + action history in a Postgres DB, and exposes a Next.js UI
(plus GraphQL) for browsing it.

## What bb-portal gives us

| Capability | bb-scheduler `:7982` | bb-portal |
|---|---|---|
| Live view of running operations | ✓ | ✓ |
| List historical invocations by ID / user / branch | ✗ | ✓ |
| Per-invocation action timeline | ✗ | ✓ |
| Per-action stdout / stderr / inputs / outputs | partial (digest required) | ✓ (clickable from invocation) |
| Critical path analysis | ✗ | ✓ |
| Cache-hit / remote-vs-local breakdown | ✗ | ✓ (per-invocation) |
| Cross-build flakiness detection | ✗ | ✓ (planned in upstream roadmap) |
| Auth via existing Dex IdP | n/a | ✓ (OIDC, same as bb-browser) |

## Architecture sketch

bb-portal is **not** a single binary. Reading the upstream tree
(`buildbarnrepos/bb-portal`) reveals three deliverables:

* **bb-portal-backend** (`cmd/bb_portal`, image
  `ghcr.io/buildbarn/bb-portal-backend`) — Go binary that hosts an
  HTTP server (UI/GraphQL/gRPC-Web/frontend reverse-proxy on `:8081`),
  an optional BES gRPC ingest server (`:8082`), an optional
  diagnostics server (`:9980`) that exposes Prometheus-format
  `/metrics` and `/debug/pprof/` for ad-hoc inspection (no scraper
  hooked up to it today). All three "logical services" live in one
  process and are toggled on/off via the
  jsonnet config (`besServiceConfiguration`,
  `browserServiceConfiguration`, `schedulerServiceConfiguration`).
* **bb-portal-frontend** (image `ghcr.io/buildbarn/bb-portal-frontend`)
  — Next.js UI on `:3000`. Internal-only; the backend reverse-proxies
  every non-API HTTP request to it (`frontend_proxy_url`).
* **Postgres** — schema is managed by entgo migrations on backend
  startup; SQLite was supported once but the proto field is
  `reserved 1` now (Postgres-only as of HEAD).

Connectivity:

```
            external (HTTPS / grpcs)              internal docker network
            ─────────────────────────             ───────────────────────
                    │
                    │ user browser
                    ▼
         ┌──────────────────────┐
         │  bb-portal-backend   │  ─ HTTP reverse-proxy ─►  bb-portal-frontend
         │  :8081 → public 7986 │      to Next.js UI         (Next.js, :3000,
         │  (oidc{} via Dex)    │                            internal-only)
         └──────────┬───────────┘
                    │ pgx
                    ▼
              ┌─────────────┐
              │ Postgres 17 │ (PDP image, internal-only :5432)
              └─────────────┘
                    ▲
                    │ writes invocations / actions / targets / events
                    │
         ┌──────────────────────┐         ┌────────────────────────────┐
         │  Bazel client        │ ─BES──► │ Envoy :1985 (jwt_authn,    │
         │  --bes_backend=      │  gRPC   │  remote_jwks at Dex /keys) │
         │   grpcs://…:1985     │  + JWT  │            │                │
         └──────────────────────┘         │            ▼                │
                                          │   bb-portal-backend :8082   │
                                          │   (allow{} — trusts Envoy)  │
                                          └────────────────────────────┘
```

Both inbound surfaces (UI :7986, BES :1985) sit behind the existing
public TLS terminator pair we already have (Envoy for gRPC, direct
TLS-on-port for HTTPS UIs). No new TLS endpoints, no new Let's
Encrypt SAN — the existing cert for `${PUBLIC_HOSTNAME}` covers them
all.

The compose stack already has the patterns we need:

* TLS cert distribution → `/etc/buildbarn/certs/{fullchain,privkey}.pem`
* Dex OIDC client registration → mirror `bb-browser`/`bb-scheduler-admin`
  (new client, `bb-portal`, allow-list `percona:build-engineers`)
* Reverse-proxy / Envoy listener for the public HTTPS port
* Smoke-test slot in `create-central.sh::smoke()`

So adding bb-portal is more "wire up another bb-storage-shaped service"
than green-field work — except for the frontend container, which is
new shape (Next.js, not a Go server).

## Scope

### In scope (MVP)

1. **bb-portal compose service.** New container in
   `compose/docker-compose.yml`, imageref pinned to a known-good upstream
   tag (`ghcr.io/buildbarn/bb-portal:<sha>`). BES gRPC on `:1985`,
   HTTPS UI on `:7986` (port chosen to mirror the `:798x` family).

2. **Postgres compose service.** Single-node, persistent volume under
   `/var/lib/buildbarn/portal-db/`. Backup story = `pg_dump` cron into
   the same `Backups` Hetzner volume we already mount on the central.
   (Retention policy: TBD during impl — likely 30 days of invocation
   metadata, ~20 MB/day order-of-magnitude.)

   **Image: `percona/percona-distribution-postgresql:17.9`** (PDP 17 line,
   pinned to a specific minor). Rationale:

   * **Vanilla-PG ABI / wire protocol.** bb-portal talks to the DB via
     Go's [entgo.io](https://entgo.io/) ORM over `lib/pq`; PDP is just
     vanilla PostgreSQL with extra extensions bundled (none active by
     default — see below). Drop-in replacement for `postgres:17` without
     code changes on the bb-portal side.
   * **Dogfooding.** Percona's own build farm running on Percona's own
     PostgreSQL distribution is a fine internal-stability signal.
     Production-grade Verified Publisher image, multi-arch (amd64/arm64),
     released within days of upstream PG patch cycle.
   * **Pinned minor on purpose.** `:17.9` rather than `:17` or `:latest`
     so a docker pull at random replatform-time can't surprise us with
     a major or minor bump while our schema migration code (entgo
     auto-migrate) is mid-run. Bump deliberately, after smoke-test
     against bb-portal HEAD.

   PDP-specific quirks the operator runbook must call out:

   | What | Value | Why it matters |
   |---|---|---|
   | `PGDATA` | `/data/db` | Bind-mount `/var/lib/buildbarn/portal-db` here, **not** at the Debian-default `/var/lib/postgresql/data`. |
   | postgres user UID | `26` (RHEL) | Volume must be `chown -R 26:26 …` before first start, otherwise `initdb` fails on permissions. |
   | Base image | `redhat/ubi9-minimal` | ~535 MB compressed (vs ~80 MB for `postgres:17-alpine`). One-time pull on the central; not a hot path. |
   | Bundled extensions on disk | `pg_tde`, `pg_stat_monitor`, `pg_repack`, `pgaudit`, `pgaudit_set_user`, `pgvector`, `wal2json`, `pgbackrest`, `patroni` | None added to `shared_preload_libraries`; runtime overhead = 0 unless we explicitly `CREATE EXTENSION …` or edit `postgresql.conf`. So they cost ~50 MB of layer space and otherwise sit dormant. |
   | Future upgrade path | `pgbackrest` already in image | When we outgrow `pg_dump` (PITR, incremental, off-host), no image swap needed — just enable. Same for `pgaudit` if a compliance ask ever lands. |

   First-boot checklist (capture in `create-central.sh::smoke()`):

   ```sql
   -- expect empty / no Percona extensions auto-loaded
   SHOW shared_preload_libraries;
   -- expect only what bb-portal's entgo migration created (uuid-ossp at most)
   \dx
   ```

   If either query shows something we didn't ask for, the runbook
   instructs the operator to override `shared_preload_libraries=''` via
   `command:` in compose, rather than baking a custom postgresql.conf
   layer.

3. **Dex OIDC integration.** New static client `bb-portal` in
   `compose/dex/dex.yaml`, redirect URI `https://bb-psmdb.ddns.net:7986/auth/callback`,
   GitHub team gate identical to bb-browser:
   `percona:build-engineers`.

4. **Bazel client wiring (PSMDB-2043 follow-up).** Add to
   `.bazelrc.psmdb`:
   ```
   common:psmdb_buildfarm --bes_backend=grpcs://bb-psmdb.ddns.net:1985
   common:psmdb_buildfarm --bes_results_url=https://bb-psmdb.ddns.net:7986/invocations/
   ```
   The same OIDC bearer that `wrapper_hook.py` injects for
   `--remote_executor` is automatically forwarded by Bazel as
   `--bes_header=authorization=Bearer …` if we add that line too. To
   verify: check whether bb-portal's BES authenticator can validate
   Dex-issued JWTs the same way Envoy `jwt_authn` does (it should — same
   JWKS endpoint).

5. **create-central.sh smoke tests.** Mirror what we do for browser /
   scheduler-admin: 302 to Dex `/auth?client_id=bb-portal`, Postgres
   reachable, BES gRPC accepting connections.

6. **Documentation.** Per-feature note in `ondemand/README.md` ("How
   do I find a failed build by invocation_id?"), redirect from the
   "no historical lookup" caveat in `buildbarn-auth-tls-plan.md` §5d
   over to this doc.

### Out of scope (deliberate)

* **No deprecation of bb-browser / bb-scheduler-admin in Phase 1.** Even
  though bb-portal can replace both (`browserServiceConfiguration` /
  `schedulerServiceConfiguration` in the jsonnet are deliberately
  commented out for now), Phase 1 is coexistence: portal runs alongside.
  Phase 2 (separate plan-update) covers the deprecation; see
  "Phase 2 — Deprecation roadmap" below.
* **No retention beyond 30 days.** Long-term archival of build telemetry
  is a separate, larger conversation (storage cost, GDPR-ish concerns
  if we ever expose this externally).
* **No cross-org sharing.** bb-portal stays GitHub-team-gated to
  Percona build engineers, same as the rest of the stack.
* **No replacement of EngFlow** for non-PSMDB MongoDB builds. Other
  branches keep using the upstream EngFlow flow; bb-portal only sees
  invocations that hit `--config=psmdb_buildfarm`.
* **No Slack / Teams notifications** in MVP. Possibly later via the
  GraphQL subscription API.

## Phase 2 — Deprecation roadmap

After bb-portal has been the daily driver for ≥2 weeks with no
operator complaints, we collapse the three UIs into one. Net delta:
fewer Dex clients, fewer container images to track, one Let's Encrypt
SAN's worth of public surface less.

> **Why "no operator complaints" rather than "metrics show parity"?**
> Today this stack has no Prometheus / Grafana scraping the
> `enablePrometheus: true` endpoints scheduler / storage / portal
> already expose — see `buildbarn-ondemand-scaler.md` §"Observability
> dashboard" (post-MVP "if Percona's Prometheus is available"). Until
> a scraper lands, the Phase-2 gate is operator-judgment based: weekly
> review of `docker compose logs bb-portal-backend` for crashes /
> 5xx-bursts, plus a Postgres `SELECT count(*) FROM invocations WHERE
> ingested_at > now() - '7 days'::interval` to confirm BES events
> keep flowing.

| Touch | Phase 2 change |
|---|---|
| `compose/docker-compose.yml` | Delete the `bb-browser` service stanza entirely. |
| `compose/config/scheduler.jsonnet` | Drop `adminHttpServers` (the `:7982` UI binding); the scheduler keeps its gRPC server on `:8983` for workers. |
| `compose/config/bb-portal.jsonnet` | Uncomment and fill in `browserServiceConfiguration` / `schedulerServiceConfiguration` blocks (point at the same `frontend:8980` and `scheduler:8984` the standalone services were pointing at). |
| `compose/dex/dex.yaml` | Delete the `bb-browser` and `bb-scheduler-admin` static clients. |
| `create-central.sh::bake_env()` | Stop generating `BB_BROWSER_OIDC_SECRET`, `BB_SCHED_OIDC_SECRET`, `BB_BROWSER_COOKIE_SEED`, `BB_SCHED_COOKIE_SEED`. Operators with old `.env` files keep them around as dead vars (harmless). |
| `create-central.sh::smoke()` | Drop the `:7982` and `:7984` smoke probes; the `:7986` probe (added in Step 5 of Phase 1) covers both via the merged UI. |
| `INFRASTRUCTURE.md.example` | Update the cert / OIDC sections — three clients become one. |
| Bazel client docs (`.bazelrc.psmdb`, `wrapper_hook` notes) | Repoint any blob-archive deep-links from `:7984/blobs/...` to `:7986/browser/blobs/...` (the upstream codebase emits the prefix configurably — TBD where the prefix lives, likely `compose/config/scheduler.jsonnet::browserUrl`). |
| Hetzner firewall (when Step 6 of auth/TLS plan eventually lands) | Close `:7982` and `:7984` on the public floating IP; only `:7986` and `:1985` remain. |

Phase 2 has its own go/no-go gate: if the merged UI shows any UX
regression versus standalone bb-browser (slow blob loads, broken
deep-links, scheduler-admin operator actions missing) we hold the
deprecation and file the gap upstream.

## Steps

### Step 1 — Upstream readiness check (DONE — 2026-04-29)

Verified against `buildbarnrepos/bb-portal` HEAD (`91f89aa`, "Atomic
operation for inserting invocations") and the matching ghcr.io tag
`20260420T074351Z-91f89aa` (published 2026-04-20).

| Check | Finding | Source |
|---|---|---|
| Latest stable image | `ghcr.io/buildbarn/bb-portal-backend:20260420T074351Z-91f89aa` + `ghcr.io/buildbarn/bb-portal-frontend:` (same SHA suffix). 9-day-old at lookup time. | ghcr.io/buildbarn/bb-portal-backend |
| One image or two? | **Two.** Backend (Go) and frontend (Next.js) are separate containers; backend reverse-proxies non-API HTTP traffic to frontend via `frontend_proxy_url`. | `bb-portal/README.md`, "Setting Up" / "Running" sections |
| Postgres support | Postgres-only at HEAD; `reserved 1` on the SQLite oneof source field — i.e. SQLite was deliberately removed. Driver is `pgx` (`github.com/jackc/pgx/v5`); connection string is a standard `postgresql://` URL. | `pkg/proto/configuration/bb_portal/bb_portal.proto:55-65` |
| Postgres version | entgo migrations run cleanly on PG 13+. We pin **PDP 17.9** (vanilla PG 17 wire-protocol with Percona's distribution). PDP 18 only GA'd in April 2026 — adopt only after a deliberate smoke-test cycle. | (this plan, §"Scope → 2") |
| UI auth (HTTPS UI :8081) | Inherits bb-storage's `http.server.AuthenticationPolicy` which supports `oidc{}` (full redirect flow, encrypted session cookies). **Same shape** as bb-browser/bb-scheduler-admin — we can reuse the OIDC helper from `compose/config/common.libsonnet`. | `bb-storage/pkg/proto/configuration/http/server/server.proto:79-155` |
| BES ingest auth (gRPC :8082) | Inherits bb-storage's `grpc.AuthenticationPolicy` — supports `jwt{}` against a JWKS, but **NOT remote JWKS URL** (intentional — `jwt.proto:36-52` cites availability + thundering-herd reasons). Mitigation: see "Auth wiring decision" below. | `bb-storage/pkg/proto/configuration/jwt/jwt.proto:28-53` |
| `--bes_header=authorization=Bearer …` | Bazel will forward whatever headers the user sets; the rate-limiting factor is the BES gRPC server's auth policy, not the client. With our chosen wiring (Envoy-passthrough, see below), Envoy validates the same JWT it already validates for `:8981` Bazel-execution traffic. | `wrapper_hook.py` already injects `--remote_header=authorization=Bearer …`; we add a sibling `--bes_header=…` |
| Replaces existing UIs? | **Yes.** `BrowserService` exposes the same `BlobAccessConfiguration` as bb-browser; `SchedulerService` exposes the same `BuildQueueState` client as bb-scheduler-admin. README §"BB-scheduler" / §"BB-browser" explicitly call this out. URL prefix for blob deep-links becomes `https://${PUBLIC_HOSTNAME}:7986/browser/…` (vs `:7984/…`). | `bb-portal/README.md:117-123` |
| bb-deployments reference | None — `buildbarnrepos/bb-deployments/docker-compose/docker-compose.yml` does not include bb-portal. We're writing the compose shape ourselves. | `grep bb-portal bb-deployments` returns 0 matches |
| Resource budget | Wiki sample asks 8 GB request / 16 GB limit *per* container, both backend and frontend. **Not realistic** on cpx42 (16 GB total RAM, already shared with frontend/scheduler/storage/dex/envoy/scaler). Start the impl with 1 GB frontend / 2 GB backend / 1 GB Postgres and tighten via observation. | [bb-portal Wiki — Sample Deployment][wiki-sample] (quoted below) |

[wiki-sample]: https://github.com/buildbarn/bb-portal/wiki/Sample-Deployment

The "Resource budget" finding is not in our local clone of bb-portal —
the GitHub Wiki is a separate `<repo>.wiki.git` repository, not part
of the main code tree. Quoted directly from the wiki's `deployment.yml`
so the plan stays self-contained:

```yaml
        - name: frontend
          image:  ghcr.io/buildbarn/bb-portal-frontend
          resources:
            requests:
              memory: "8Gi"
              cpu: "1"
            limits:
              memory: "16Gi"
              cpu: "2"
        - name: backend
          image: ghcr.io/buildbarn/bb-portal-backend
          resources:
            requests:
              memory: "8Gi"
              cpu: "1"
            limits:
              memory: "16Gi"
              cpu: "2"
```

This is k8s-shaped (Pod resources block) and assumes a deployment with
plenty of headroom — not appropriate for a single shared cpx42 host
which currently runs ten or so other BuildBarn containers. The
"start at 1 GB / 2 GB / 1 GB and observe" rule of thumb in the table
above is our cpx42-aware over-ride; we revisit if `docker stats`
shows any of the three sustained at >70% of its assigned ceiling.

##### Host upgrade path if bb-portal pushes the central over budget

Adding bb-portal-frontend + bb-portal-backend + bb-portal-db ≈ 4 GB
of new RSS to a host whose existing baseline (frontend / scheduler /
storage shards / dex / envoy / scaler / bb-browser / bb-scheduler-admin)
we have not yet measured. If observation shows the cpx42's 16 GB are
oversubscribed, Hetzner's `change-type` (a.k.a. "rescale") flow
upsizes the SAME VM in place — no delete, no detach/attach of the
data volume, no floating-IP juggling:

| Type | Cores | RAM | Boot disk | hel1/nbg1/fsn1 monthly | Why |
|---|---|---|---|---|---|
| `cpx42` (current) | 8 vCPU shared | 16 GB | 320 GB local | ~€17 | Day-1 size; tight if portal lands |
| `cpx52` | 12 vCPU shared | 24 GB | 480 GB local | ~€27 | Middle-ground bump |
| **`cpx62`** | **16 vCPU shared** | **32 GB** | **640 GB local** | **~€50.49** | **Likely target** if 16 GB proves too tight; 2× RAM, 2× cores. Was the size of the *original* `bb-psmdb` host before the ondemand cut-over (see `buildbarn-ondemand-scaler.md:52`). |
| `ccx23` | 4 cores **dedicated** | 16 GB | 80 GB NVMe | ~€55 | **Different family — `change-type` cannot reach this from `cpx*`.** Requires the full delete-and-recreate dance from `buildbarn-ondemand-scaler.md` §5.1. Only matters if shared-CPU jitter (not RAM) becomes the bottleneck. |

`hcloud server-type describe cpx62`:

```
Cores:        16
CPU Type:     shared
Architecture: x86
Memory:       32.0 GB
Disk:         640 GB
Storage Type: local
Pricings per Location:
  - hel1:  Hourly: € 0.0809   Monthly: € 50.49
  - nbg1:  Hourly: € 0.0809   Monthly: € 50.49
  - fsn1:  Hourly: € 0.0809   Monthly: € 50.49
```

Trigger criteria (any one is enough — gate on observation, not theory):

* `docker stats` shows the cpx42 sustained at >85 % memory utilisation
  for ≥30 min during a normal workday.
* OOM-killer touches any BuildBarn process — `dmesg | grep -i 'killed process'`
  on the central host returns matches inside the bb-portal-* / bb-* set.
* New `:9980/metrics` endpoint reports
  `process_resident_memory_bytes` close to a self-imposed 2 GB cap
  more than briefly (only relevant once a Prometheus scraper exists).

###### Execution — `hcloud server change-type` (in-place rescale)

Hetzner's documented constraints, verbatim from their console help
text:

> **Rescale.** You need more performance? Just scale up to a more
> powerful plan. You have the option to rescale your CPU and RAM
> only and leave your server's disk untouched or expand the disk as
> well. A downgrade is only possible if you leave the disk as is.
> You are not able to downgrade to a plan with a smaller disk.
> **Your server needs to be powered off, in order to be rescaled.
> The process will usually take just a few minutes.**

Translated to our setup:

* **Power-off is mandatory.** All eight central containers go down
  during the swap; that is the entire downtime window. Plan a
  maintenance slot when no Bazel builds are in flight (or accept
  that in-flight builds will retry against cache once we're back).
* **`--keep-disk` keeps the boot disk at 320 GB.** Our boot disk
  carries only the OS + docker layers (everything BuildBarn cares
  about — CAS, configs, certs, Postgres `/data/db`, OIDC secrets
  — lives on the attached xfs volume `psmdb-buildbarn-cas-ondemand`,
  which `change-type` does not touch). Keeping the boot disk size
  preserves the *option* to downgrade later: Hetzner only allows a
  smaller-RAM rescale when the disk hasn't grown since the last
  one.
* **Same family only.** `cpx42 → cpx52 → cpx62` are all the same
  shared-vCPU CPX family, so `change-type` works between any of
  them. Crossing into `ccx*` (dedicated) requires the full rebuild
  recipe in `buildbarn-ondemand-scaler.md` §5.1; see "When
  `change-type` is NOT enough" below.

Recipe (single VM, single command set, no state migration):

```bash
# 1. Drain & power off — usually just stop compose first so containers
#    exit cleanly instead of via SIGKILL on poweroff.
ssh root@"$PUBLIC_HOSTNAME" 'cd /var/lib/buildbarn/compose && docker compose down'
hcloud server poweroff   bb-psmdb-ondemand

# 2. Rescale CPU+RAM only (boot disk stays 320 GB; keeps downgrade open).
hcloud server change-type bb-psmdb-ondemand cpx62 --keep-disk

# 3. Power back on; compose services restart automatically because each
#    one has restart: unless-stopped.
hcloud server poweron    bb-psmdb-ondemand

# 4. Smoke-check (run from local machine after a ~30 s warm-up).
curl -kI https://"$PUBLIC_HOSTNAME":7984/   # bb-browser
curl -kI https://"$PUBLIC_HOSTNAME":7986/   # bb-portal-frontend
```

Hetzner reports the rescale itself "usually takes just a few
minutes" — in practice we've seen 3–5 min for the API operation,
plus ~1 min for compose to come back up. **Total downtime budget:
~10 min**, dominated by container shutdown + startup, not by the
rescale itself. `create-central.sh` does NOT need to re-run — none
of its inputs (volume, network, SSH keys, floating IP, certs, .env)
change during a rescale.

Cost delta: +€33/month over current cpx42, well below the per-build
cost of ondemand workers (single full-matrix build ≈ €5–10 of cpx42
worker time). If portal observation pushes us here, that's a clean
budget conversation, not a budget surprise.

###### When `change-type` is NOT enough

`change-type` only works between server types in the **same CPU
family** (shared ↔ shared, or dedicated ↔ dedicated, NOT shared ↔
dedicated). If we ever conclude that shared-vCPU jitter — not RAM —
is the bottleneck and want to move to `ccx23`, that's a family
change. The recipe in `buildbarn-ondemand-scaler.md` §5.1 ("VM is
replaceable, state is portable" — `volume detach → server delete →
server create --type ccx23 → volume attach → floating-ip assign →
compose up`) is the right path there, and it stays the canonical
reference for the cross-family case. We just don't need it for the
cpx42 → cpx62 RAM bump that bb-portal might trigger.

Two decisions taken now to keep the rest of the plan concrete:

#### Decision A — Coexistence first, deprecate later

Phase 1 of impl: bb-portal stands up on a brand-new host port (`:7986`
HTTPS UI, `:1985` BES gRPC) **alongside** the existing bb-browser
(`:7984`) and bb-scheduler-admin (`:7982`). Both UIs answer in
parallel. This costs us one extra Dex client and a few hundred MB of
RAM but means a bug in bb-portal can't take out historical /
runtime-state UIs that the team relies on today.

Phase 2 (separate ticket, separate plan-update): when bb-portal has
been the daily driver for ≥2 weeks with no operator complaints, we
delete the `bb-browser` compose service, drop the `:7982`
adminHttpServers binding from `scheduler.jsonnet`, and shrink the
`compose/dex/dex.yaml` static-clients list from three to one. Until
then both stacks stay live.

#### Decision B — JWT validation lives in Envoy, not in bb-portal

bb-portal's built-in JWT validator can't pull JWKS from Dex over HTTP
(see check above). Two ways out: (a) cron-fetch the JWKS to a file +
rely on bb-portal's 300-second auto-reload, or (b) terminate JWT
validation in Envoy on `:1985` — the same way we already do for
Bazel-execution traffic on `:8981` — and let bb-portal trust the
upstream connection (`allow{}`).

We choose **(b)**. Rationale:

* **Single auth boundary.** Envoy's `jwt_authn` filter already pulls
  Dex's JWKS via `remote_jwks` (with file-cache fallback). Adding a
  parallel cron-fetch path doubles the moving parts and the failure
  modes for the same security guarantee.
* **Re-uses tested code path.** `:8981` (Bazel execution) has been
  running on this exact wiring for weeks; the auth bug surface is
  already shaken out.
* **Cleaner separation.** bb-portal becomes a "pure data" service:
  TLS terminates, JWT validates, the request reaches bb-portal
  pre-authenticated. bb-portal config gets `authentication_policy: { allow: {} }`
  on its gRPC server, which matches the upstream sample exactly.

Trade-off: the Envoy listener configuration grows by one cluster
(`bb-portal-backend:8082`) and one filter chain (or vhost, depending
on how envoy.yaml is structured today). Acceptable.

#### Output

Pinned image tags, Postgres version, and the two decisions above
are inputs to Step 2 (compose / config files) and Step 3 (public
exposure). No more upstream readiness gates remain.

### Step 2 — Compose / TLS / config files

Three new services in `compose/docker-compose.yml`: a Postgres backend
(`bb-portal-db`), the Go bb-portal backend (`bb-portal-backend`), and
the Next.js frontend (`bb-portal-frontend`). Tags pinned per Step 1
findings.

```yaml
services:

  # Postgres for bb-portal — see plan §"Scope → 2" for PDP rationale.
  bb-portal-db:
    image: percona/percona-distribution-postgresql:17.9
    container_name: bb-portal-db
    restart: unless-stopped
    networks: [buildbarn]
    user: "26:26"                       # PDP postgres UID (RHEL convention)
    environment:
      POSTGRES_USER: bbportal
      POSTGRES_PASSWORD_FILE: /run/secrets/bb_portal_db_password
      POSTGRES_DB: bbportal
    secrets:
      - bb_portal_db_password
    volumes:
      - /var/lib/buildbarn/portal-db:/data/db   # PDP PGDATA, not Debian default
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U bbportal -d bbportal"]
      interval: 10s
      timeout: 5s
      retries: 5
    expose: ["5432"]                    # internal-only, no host publish

  # Go backend: HTTP+gRPC-Web on 8081, BES gRPC on 8082, diag on 9980.
  # Tag pinned to the same SHA as the frontend below.
  bb-portal-backend:
    image: ghcr.io/buildbarn/bb-portal-backend:${BB_PORTAL_TAG}
    container_name: bb-portal-backend
    restart: unless-stopped
    networks: [buildbarn]
    depends_on:
      bb-portal-db: { condition: service_healthy }
    environment:
      # Read by config/bb-portal.jsonnet via std.extVar(...). Keeps the
      # password out of the rendered config that lives on disk.
      BB_PORTAL_DB_PASSWORD_FILE: /run/secrets/bb_portal_db_password
    secrets:
      - bb_portal_db_password
    command:
      - /bb-portal
      - /config/bb-portal.jsonnet
    volumes:
      - ./config/bb-portal.jsonnet:/config/bb-portal.jsonnet:ro
    expose: ["8081", "8082", "9980"]    # exposed via Envoy / direct HTTPS, see §3

  # Next.js UI. Internal-only; backend reverse-proxies non-API HTTP
  # traffic to it via frontend_proxy_url.
  bb-portal-frontend:
    image: ghcr.io/buildbarn/bb-portal-frontend:${BB_PORTAL_TAG}
    container_name: bb-portal-frontend
    restart: unless-stopped
    networks: [buildbarn]
    environment:
      NEXT_PUBLIC_BES_BACKEND_URL: https://${PUBLIC_HOSTNAME}:7986
      NEXT_PUBLIC_BES_GRPC_BACKEND_URL: grpcs://${PUBLIC_HOSTNAME}:1985
      NEXT_PUBLIC_BROWSER_URL: https://${PUBLIC_HOSTNAME}:7986/browser
      NEXT_PUBLIC_COMPANY_NAME: "Percona PSMDB"
      # Disable feature flags we don't want in MVP (BEP file upload via
      # the UI is a footgun — accidental upload of stale events from a
      # developer laptop; we only want gRPC ingest from CI / Bazel).
      NEXT_PUBLIC_ENABLED_FEATURES_BEP_UPLOAD: "false"
    expose: ["3000"]                    # internal-only, proxied through backend

secrets:
  bb_portal_db_password:
    file: ./secrets/bb_portal_db_password
```

The `BB_PORTAL_TAG` value (e.g. `20260420T074351Z-91f89aa`) is bumped
deliberately during the Phase-1 deploy and pinned in `.env`. The
`bb_portal_db_password` secret file is auto-generated on first run by
`create-central.sh::bake_env()` via `openssl rand -hex 32` and
preserved across re-runs — same pattern we already use for
`BB_BROWSER_OIDC_SECRET` / `BB_SCHED_OIDC_SECRET`.

#### Pre-create directories with the correct ownership

PDP runs Postgres as UID 26 (RHEL); the Next.js frontend image runs
as the default `node` UID. Both bind-mounts must exist with the right
ownership BEFORE `docker compose up`, otherwise initdb / `npm run
start` fails on permission errors. Add these idempotently to
`create-central.sh` next to the existing `mkdir
/var/lib/buildbarn/{certs,letsencrypt}` block:

```bash
mkdir -p /var/lib/buildbarn/portal-db
chown -R 26:26 /var/lib/buildbarn/portal-db
mkdir -p /var/lib/buildbarn/compose/secrets
chmod 700 /var/lib/buildbarn/compose/secrets
```

#### `compose/config/bb-portal.jsonnet`

Port-of-call for OIDC and database wiring. Skeleton — exact JMESPath
expressions to be tuned during impl from the actual Dex JWT shape:

```jsonnet
local common = import 'common.libsonnet';

{
  global: {
    diagnosticsHttpServer: {
      httpServers: [{ listenAddresses: [':9980'], authenticationPolicy: { allow: {} } }],
      // Exporter only — we do NOT run a Prometheus scraper today. Endpoint
      // stays available for the future "observability dashboard" task
      // (see buildbarn-ondemand-scaler.md §"Improvements") and for ad-hoc
      // ssh-into-central + curl :9980/metrics during incident response.
      enablePrometheus: true,
      enablePprof: true,
    },
  },
  frontendProxyUrl: 'http://bb-portal-frontend:3000',
  allowedOrigins: ['https://__PUBLIC_HOSTNAME__:7986'],

  // UI / GraphQL / gRPC-Web — public-facing, OIDC via Dex.
  httpServers: [{
    listenAddresses: [':8081'],
    authenticationPolicy: common.oidcAuthPolicy('bb-portal'),  // see §3
    tls: common.tlsServerConfig,
  }],

  instanceNameAuthorizer: { allow: {} },
  maximumMessageSizeBytes: 2 * 1024 * 1024,

  besServiceConfiguration: {
    grpcServers: [{
      listenAddresses: [':8082'],
      // Plain trust — Envoy on :1985 already validated the JWT.
      // See plan §"Step 1 → Decision B".
      authenticationPolicy: { allow: {} },
      maximumReceivedMessageSizeBytes: 10 * 1024 * 1024,
    }],
    database: {
      postgres: {
        connectionString: 'postgresql://bbportal:%(password)s@bb-portal-db:5432/bbportal?sslmode=disable' %
                          { password: std.extVar('bb_portal_db_password') },
      },
      connectionPoolConfiguration: {
        maxOpenConnections: 10,
        maxIdleConnections: 10,
        connectionMaxLifetime: '120s',
        connectionMaxIdleTime: '30s',
      },
    },
    enableBepFileUpload: false,
    // Production-mode toggle — true on dev clusters for debugging GraphQL
    // schemas, false here so we don't expose unauthenticated playground
    // even by accident.
    enableGraphqlPlayground: false,
    saveDataLevel: { basicAndTarget: {} },
    databaseCleanupConfiguration: {
      cleanupInterval: '60s',
      invocationMessageTimeout: '3600s',
      invocationRetention: '2592000s',   // 30 days; see plan §"Out of scope"
    },
    minEventBatchDuration: '0.1s',
  },

  // Phase 1 (coexistence): leave these unset for now. bb-browser and
  // bb-scheduler-admin still serve the same data on their own ports.
  // Phase 2 (replacement): wire these in and then drop the standalone
  // bb-browser / scheduler-admin services.
  // browserServiceConfiguration: { ... },
  // schedulerServiceConfiguration: { ... },
}
```

Notes:

* The bb-storage common helper (`compose/config/common.libsonnet`)
  already has `oidcAuthPolicy(clientId)` from the auth/TLS plan
  (Step 4); we reuse it as-is.
* `std.extVar('bb_portal_db_password')` is set by an
  `--ext-str-file=bb_portal_db_password=/run/secrets/bb_portal_db_password`
  added to the backend's `command:` once we settle on the exact
  jsonnet evaluator entry shape (might be done at config-bake time
  in `create-central.sh::bake_env()` instead, mirroring how we
  already render OIDC secrets).
* `__PUBLIC_HOSTNAME__` is sed-replaced at bake time, same pattern as
  `__BB_PUBLIC_URL__` / `__BB_OIDC_ISSUER__` in the existing
  `common.libsonnet`.

#### `compose/dex/dex.yaml` — new static client

Append a fourth entry beside `bb-browser`, `bb-scheduler-admin`,
`bazel-cli`:

```yaml
staticClients:
  - id: bb-portal
    name: bb-portal
    secret: $BB_PORTAL_OIDC_SECRET     # auto-generated by bake_env()
    redirectURIs:
      - https://${PUBLIC_HOSTNAME}:7986/auth/callback
```

The redirect URI matches `OIDCAuthenticationPolicy.redirect_url` we
plug into `bb-portal.jsonnet` (path `/auth/callback`, mirrors
bb-browser).

#### `bake_env()` additions

Three new entries in the generated `.env`:

```sh
BB_PORTAL_TAG=20260420T074351Z-91f89aa     # pinned at impl time
BB_PORTAL_OIDC_SECRET=<openssl rand -hex 32, preserved across re-runs>
BB_PORTAL_COOKIE_SEED=<openssl rand -hex 32, preserved across re-runs>
```

Plus the secret file `/var/lib/buildbarn/compose/secrets/bb_portal_db_password`
(`openssl rand -hex 32`, preserved across re-runs the same way the
OIDC seeds already are — `_env_get` lookback against the previous
`.env`).

### Step 3 — Public exposure

Two new public ports, paralleling the auth/TLS-plan layout:

| External | Protocol | Internal target | TLS / auth boundary |
|---|---|---|---|
| `${PUBLIC_HOSTNAME}:7986` | HTTPS | `bb-portal-backend:8081` | bb-portal terminates TLS itself, runs OIDC redirect flow against Dex (`oidcAuthPolicy('bb-portal')`) — **same shape** as bb-browser :7984 today |
| `${PUBLIC_HOSTNAME}:1985` | grpcs | `bb-portal-backend:8082` | **Envoy** terminates TLS and validates JWT via existing `jwt_authn` filter (Decision B from Step 1). bb-portal sees plain gRPC + `allow{}` |

#### UI port :7986

Cleanest pattern: bb-portal-backend itself binds `:7986` on the host
private interface (mirroring bb-browser's `:7984` mapping), with the
shared LE cert mounted from `/var/lib/buildbarn/certs/`. Add to the
service block:

```yaml
  bb-portal-backend:
    ports:
      - "${PUBLIC_IP}:7986:8081"
    volumes:
      - /var/lib/buildbarn/certs:/etc/buildbarn/certs:ro
      - ./config/bb-portal.jsonnet:/config/bb-portal.jsonnet:ro
```

The `tls:` block in the jsonnet (`common.tlsServerConfig` helper
already used by bb-browser/scheduler-admin) points at
`/etc/buildbarn/certs/{fullchain,privkey}.pem`. No new cert SAN —
the existing `${PUBLIC_HOSTNAME}` cert covers `:7986`.

#### BES port :1985

Add a new listener to `compose/reapi-proxy/envoy.yaml`:

```yaml
listeners:
  - name: bes_grpc
    address: { socket_address: { address: 0.0.0.0, port_value: 1985 } }
    filter_chains:
      - transport_socket: <reuse the existing TLS context block>
        filters:
          - name: envoy.filters.network.http_connection_manager
            typed_config:
              # gRPC over HTTP/2 with the same JWT filter we already use on :8981.
              http_filters:
                - name: envoy.filters.http.jwt_authn
                  typed_config:
                    providers:
                      dex_jwt:
                        # IDENTICAL to the existing :8981 provider — keep them
                        # in lockstep. Audience is "bazel-cli" (matches the
                        # token wrapper_hook.py issues; BES events ride the
                        # same token).
                        ...
                - name: envoy.filters.http.router
              route_config:
                virtual_hosts:
                  - name: bes
                    domains: ["*"]
                    routes:
                      - match: { prefix: "/google.devtools.build.v1.PublishBuildEvent/" }
                        route:
                          cluster: bb_portal_bes
                          timeout: 0s     # streaming RPC, no client-side timeout

clusters:
  - name: bb_portal_bes
    type: strict_dns
    connect_timeout: 5s
    http2_protocol_options: {}
    load_assignment:
      cluster_name: bb_portal_bes
      endpoints:
        - lb_endpoints:
            - endpoint:
                address: { socket_address: { address: bb-portal-backend, port_value: 8082 } }
```

Then publish the listener on the host:

```yaml
  envoy-proxy:
    ports:
      - "${PUBLIC_IP}:1985:1985"
```

Two specifics that bit us on `:8981` and we want to avoid repeating:

* **`timeout: 0s` on the route** — BES is a long-lived bidirectional
  streaming RPC; default Envoy timeouts will close the upload mid-build.
* **`maximumReceivedMessageSizeBytes: 10 * 1024 * 1024` on bb-portal**
  — we set this in the jsonnet (Step 2). Bazel BES events on a busy
  PSMDB build can hit a few MB per batch; 10 MiB gives headroom.

Net result: workers don't talk to bb-portal (workers ride a separate
private path for CAS — see `buildbarn-auth-tls-plan.md` §5d). Only
public Bazel clients (laptops, Jenkins) ingest BES events, and they
ride the same Envoy + JWT path they already use for execution.

### Step 4 — Bazel client wiring

* Edit `.bazelrc.psmdb` (in the `psmdb_buildfarm` config block) to add
  `--bes_backend` / `--bes_results_url` / `--bes_header=authorization=Bearer …`.
* `wrapper_hook.py` already injects the OIDC bearer for
  `--remote_header`. Verify Bazel forwards the same to BES (via
  `--bes_header=authorization=Bearer ${token}`) — if not, extend
  `wrapper_hook.py` to inject both headers in one pass.

### Step 5 — Smoke tests

In `scripts/create-central.sh::smoke()`:

* TCP listener on `:1985` (BES gRPC) and `:7986` (HTTPS UI).
* Unauthenticated GET `/` → 302 to Dex `/auth?client_id=bb-portal`.
* `psql -U bb_portal -d bb_portal -c 'SELECT 1'` from inside the
  postgres container → returns 1.
* Authenticated GraphQL probe (`{ invocations(first: 1) { nodes { id }}}`)
  with the maintainer's id_token via `rbe_login.py --print-token` → 200.

### Step 6 — Operator runbook

* `ondemand/README.md`: new section "Finding a historical build" with
  step-by-step (paste invocation ID into bb-portal URL, drill in).
* Backup / restore drill for `portal-db/` volume.
* `bb-portal` log rotation / retention policy (cron).

## Open questions

1. **Storage growth.** Empirically, how many MB / GB does an average
   PSMDB build produce in BES events? Determines whether 30 days of
   retention fits the existing `Backups` volume or needs a dedicated one.

2. **HA / replication.** Out of scope for MVP, but if PSMDB CI
   eventually depends on bb-portal as the source of truth for "did
   build X pass", we'll need a replicated Postgres setup or a hot
   backup. Track separately.

3. **Multi-tenant?** Is the long-term plan to point ALL Percona-side
   Bazel builds (PG, Toolkit, etc.) at this single bb-portal? If yes,
   the Dex OIDC group gating (currently `percona:build-engineers`)
   needs broadening, and the Postgres schema needs an `organization`
   column on most tables.

4. **PDP patch cadence vs. upstream PG.** Percona's distribution
   re-packages each upstream PG patch release with a Percona-specific
   build counter (`17.9-1`, `17.9-2`, etc.) on its own cadence — usually
   within ~5–7 days of upstream, but not in lock-step. Practical
   implication: subscribe to
   [percona-postgresql-distribution-announce](https://www.percona.com/services/announcements)
   (or watch the Docker Hub
   [tag list](https://hub.docker.com/r/percona/percona-distribution-postgresql/tags))
   and bump the pinned tag deliberately during a maintenance window
   rather than chasing `:17` floating. Track CVE coverage per Percona's
   advisories, not directly off postgresql.org's release notes — the
   patch may already be packaged with a slight delay, or hot-patched
   sooner if Percona has a fix ready earlier than upstream tag-time.

5. **TDE on by default (or not)?** PDP ships `pg_tde` on disk but
   inactive. bb-portal data is build telemetry (no PII, no customer
   secrets), so encryption-at-rest probably isn't required at MVP — the
   underlying Hetzner volume can be encrypted at the cloud layer if
   compliance ever demands it. Decision: revisit only if Percona security
   policy explicitly asks for application-layer TDE on internal services.

## Why this is NOT in [`buildbarn-auth-tls-plan.md`](./buildbarn-auth-tls-plan.md)

The auth/TLS plan delivers a hardened **execution plane**: TLS
everywhere public, Dex OIDC for UIs, JWT for Bazel clients, private
network for workers. That work is feature-complete (steps 1-5d done as
of 2026-04-28).

bb-portal is a separate **observability plane** — a different concern
(post-mortem build analysis), with a different blast radius (read-only
historical data, not a credential gate), and a different rollout
cadence (we can stand it up while the existing stack keeps serving
production traffic). Mixing it into the auth plan would have stretched
that document past its natural scope and made it harder to mark as
"DONE" cleanly.
