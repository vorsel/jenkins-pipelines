# BuildBarn — Build Observability via bb-portal

> Status: **PROPOSED** — not yet started.
> Last update: 2026-04-29.
> Tracking: TBD (new Jira PSMDB-* ticket to be created when work begins).
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

```
┌────────────────────────────────────┐
│ Bazel client                       │
│   --bes_backend=grpc://...:1985    │
│   --bes_results_url=https://       │
│        bb-psmdb.ddns.net:7986/     │
└──────────────┬─────────────────────┘
               │ BES events (gRPC)
               ▼
┌────────────────────────────────────┐
│ bb-portal (new service)            │
│   :1985  BES gRPC ingest           │
│   :7986  HTTPS UI / GraphQL        │
│           (OIDC via Dex)           │
│   ┌──────────────────────────────┐ │
│   │ Postgres (compose service)   │ │
│   │  invocations / actions /     │ │
│   │  targets / events tables     │ │
│   └──────────────────────────────┘ │
└────────────────────────────────────┘
               ▲
               │ links to action digests
               │
┌──────────────┴─────────────────────┐
│ bb-browser :7984 (existing)        │
│  serves CAS/AC blobs;              │
│  bb-portal deep-links here         │
└────────────────────────────────────┘
```

The compose stack already has the patterns we need:

* TLS cert distribution → `/etc/buildbarn/certs/{fullchain,privkey}.pem`
* Dex OIDC client registration → mirror `bb-browser`/`bb-scheduler-admin`
  (new client, `bb-portal`, allow-list `percona:build-engineers`)
* Reverse-proxy / Envoy listener for the public HTTPS port
* Smoke-test slot in `create-central.sh::smoke()`

So adding bb-portal is more "wire up another bb-storage-shaped service"
than green-field work.

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

## Steps

### Step 1 — Upstream readiness check

Before committing to a compose-shape, verify:
* Latest stable bb-portal image tag (and its compatibility with
  `bb-storage` HEAD, since we mix-and-match).
* That bb-portal's auth supports OIDC bearer tokens issued by Dex
  (not "Built-in users" mode only).
* That its BES ingester accepts the gRPC headers Bazel sends for
  `--bes_header=authorization=Bearer …`.
* Postgres version compatibility (likely 14+).

Output: confirmation note here, image tag pinned in §3.

### Step 2 — Compose / TLS / config files

* Add `bb-portal` and `postgres` services to `compose/docker-compose.yml`.
* Add `compose/config/bb-portal.jsonnet` (or YAML — depends on what
  upstream supports) using the existing OIDC helper from
  `compose/config/common.libsonnet`.
* Add `compose/dex/dex.yaml` static client `bb-portal`.
* Persistent volume mounts: `/var/lib/buildbarn/portal-db/`,
  `/var/lib/buildbarn/portal-data/`.

### Step 3 — Public exposure

Two options, pick during impl:

a) **Direct port mapping** (`${PUBLIC_IP}:7986`). Simpler, mirrors how
   bb-browser is exposed today. bb-portal must terminate TLS itself
   (built-in HTTPS support assumed).

b) **Behind reapi-proxy / Envoy**. Adds one more virtual host entry
   to envoy.yaml. Slightly more central, but envoy is currently
   PSMDB-specific (just terminates `:8981` for Bazel) — wiring HTTP
   routing in for portal alone may not be worth it.

Default: (a) unless bb-portal can't terminate TLS natively.

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
