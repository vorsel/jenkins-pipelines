# `bb-psmdb-ondemand` — BuildBarn control plane for ephemeral workers

Green-field BuildBarn deployment that runs **only the control plane** on a
single permanent Hetzner Cloud VM. Workers are ephemeral: the `scaler`
daemon that lives next to the control plane (see [`scaler/`](scaler/))
spins Hetzner VMs up when `(distro, arch)` work is queued and tears them
down after an idle timeout.

This directory contains everything needed to stand the central node up from
an operator's laptop with one command.

## Layout

```
ondemand/
├── README.md                       ← you are here
├── compose/
│   ├── docker-compose.yml          ← frontend + 2× storage + scheduler +
│   │                                  browser + bb-portal-{db,backend,frontend} +
│   │                                  dex + reapi-proxy + envoy-proxy + scaler
│   ├── .env.example                ← copy to .env; bootstrap script writes
│   │                                  the real .env for you
│   ├── dex/dex.yaml                ← Dex IdP (GitHub connector, static clients)
│   └── config/
│       ├── common.libsonnet        ← shared blobstore / browserUrl / portalUrl
│       ├── storage.jsonnet         ← 369 GB per shard (sized for 750 GB vol)
│       ├── scheduler.jsonnet       ← admin :7982, client :8982, worker :8983,
│       │                             buildQueueState :8984
│       ├── frontend.jsonnet        ← gRPC :8980 (internal)
│       ├── browser.jsonnet         ← HTTP :7984
│       ├── bb-portal.jsonnet       ← BES gRPC ingest :8082, UI :8081
│       │                             (build observability — see
│       │                             ../buildbarn-portal-plan.md)
│       └── ondemand-pools.yaml     ← declarative pool config for the scaler
├── worker/                         ← template for an ondemand bb-worker VM
│   ├── cloud-init.yml.tmpl         ← Debian 13 + Docker + sysctl tuning (spawn-worker.sh only)
│   ├── docker-compose.yml          ← runner-installer + bb-worker + pool runner
│   └── config/
│       ├── common.libsonnet        ← blobstore → central's envoy; browserUrl
│       ├── worker.jsonnet          ← scheduler addr, concurrency, platform
│       └── runner.jsonnet          ← unix-socket runner (verbatim from prod)
├── scaler/                         ← autoscale daemon (Phase 2)
│   ├── scaler.py                   ← control loop (BuildQueueState → hcloud)
│   ├── bootstrap.py                ← cloud-init renderer (reads worker/ tree)
│   ├── Dockerfile                  ← python:3.12-slim + grpcurl
│   └── requirements.txt            ← hcloud-python + PyYAML (pinned)
└── scripts/
    ├── create-central.sh           ← one-shot bootstrap / adopt of the central
    └── spawn-worker.sh             ← create a single ondemand worker VM (manual/debug)

../reapi-proxy/                     ← shared with other BuildBarn deployments;
                                      the bootstrap script rsyncs these into
                                      /var/lib/buildbarn/reapi-proxy/
```

The **source of truth is in this repo**. Nothing on the central host is
hand-edited; everything in `/var/lib/buildbarn/compose/` and
`/var/lib/buildbarn/reapi-proxy/` is rsynced from here by the bootstrap
script and rewritten on every run.

## Infrastructure assumptions

These IDs are hard-coded as defaults in [`scripts/create-central.sh`](scripts/create-central.sh)
(override with env vars if you need a variant):

| Thing | ID | Notes |
| ----- | -- | ----- |
| Hetzner server (will be created) | name `bb-psmdb-ondemand`, `cpx42`, `hel1`, Debian 13 | 8c shared / 16 GB / 320 GB boot disk |
| Hetzner volume (must exist) | `105484418` — `psmdb-buildbarn-cas-ondemand`, 750 GB xfs | CAS/AC/FSAC backing store |
| Hetzner private network | `${HCLOUD_NETWORK_ID}` — `psmdb.cd.percona.com` (live ID in `INFRASTRUCTURE.md`) | Workers and Bazel clients live here |
| Hetzner SSH keys (both added to the server) | `24333399` (`htz.cd.key`) + `111196538` (`htz.cd.bb-psmdb-ondemand`) | The latter is the "day-to-day" key for this fleet |

## Port strategy

| Port | Service | Exposure | Rationale |
| ---- | ------- | -------- | --------- |
| `7982` | scheduler admin HTML UI | **public** | humans open this in a browser |
| `7984` | bb-browser | **public** | humans open this in a browser |
| `8981` | envoy / Bazel client gRPC | **public** | Developers and CI outside the private network need this (matches existing barn-psmdb) |
| `8983` | scheduler → workers gRPC | **private** (`${PRIVATE_IP}`) | workers come from ondemand VMs on the same private net |
| `8984` | `BuildQueueState` gRPC | **localhost** (`127.0.0.1`) | only the scaler daemon on this host consumes it |

Binding is done in [`compose/docker-compose.yml`](compose/docker-compose.yml)
via `ports:` entries. `${PRIVATE_IP}` is discovered from `hcloud server
describe` by the bootstrap script and written into `.env`.

> ⚠️ `8981` is bare gRPC (no TLS, no auth) — same posture as the existing
> `barn-psmdb`. Long term, consider a Hetzner Firewall IP allowlist or TLS
> termination, but that's out of scope for the initial green-field rollout.

## Bootstrap workflow

```bash
# one-time: ensure hcloud, jq, rsync are installed locally and HCLOUD_TOKEN
# is exported (or `hcloud context create`).

cd jenkins-pipelines/IaC/buildbarn/ondemand
./scripts/create-central.sh
```

What happens:

1. **Preflight.** Local binaries, hcloud auth, SSH key readable, repo layout
   sane, Hetzner volume/network/SSH-keys exist. Fails fast if anything is
   off.
2. **Server.** Creates `bb-psmdb-ondemand` if it doesn't exist, otherwise
   reuses the existing one. Records public + private IPs.
3. **Volume.** Attaches `105484418` to the server (no-op if already attached).
4. **Host packages.** Installs Docker via `curl -fsSL https://get.docker.com | sh`,
   plus `rsync jq xfsprogs`. Idempotent.
5. **Mount.** Mounts the xfs volume at `/var/lib/buildbarn` and adds an
   fstab entry keyed by `/dev/disk/by-id/scsi-0HC_Volume_${VOLUME_ID}` so
   reboots keep working.
6. **State detection.** Looks for `compose/docker-compose.yml` or existing
   CAS blocks on the volume:
   - *fresh* → bootstrap straight through.
   - *populated* → interactive prompt:
     - **`attach`**    keep CAS/AC data (warm cache survives), only refresh
       configs and `.env` from the repo. Existing `compose/` and
       `reapi-proxy/` snapshotted to `/var/lib/buildbarn/_backups/` first.
     - **`wipe-attach`** `mkfs.xfs` the volume (destroys cache), then do a
       fresh bootstrap.
     - **`abort`**     leave everything as-is and exit.

     Set `MODE=attach|wipe-attach|abort` to skip the prompt in automation.
7. **Config sync.** Rsyncs `compose/` and `../reapi-proxy/` onto the host,
   writes `.env` with `PRIVATE_IP`, and `sed`-replaces `__BB_PUBLIC_URL__`
   in `common.libsonnet` with `http://<public-ip>:7984`.
8. **`docker compose up -d`.** Builds the local `reapi-proxy` image, pulls
   upstream bb-* images and Envoy, brings the whole stack up.
9. **Smoke.** `curl`s the public ports, checks that the envoy-proxy
   container is running, prints a summary with all the endpoints.

## Operational recipes

**Update to a newer BuildBarn release.**
Edit `compose/.env.example` (and in `compose/docker-compose.yml` if the tag
scheme changes), commit, re-run `./scripts/create-central.sh`. The script
hits the `populated` branch → pick **attach** → the new `.env` is written,
containers are recreated, CAS data is preserved.

**Replace the host (e.g. after a hypervisor failure).**
```bash
hcloud volume detach 105484418
hcloud server delete  bb-psmdb-ondemand
./scripts/create-central.sh        # creates a new server, reattaches the
                                   # volume, picks up where we left off
# at the prompt: choose "attach"
```

**Nuke the cache deliberately.**
Re-run the script and answer `wipe-attach`.

**Roll back a config change.**
`attach` mode drops the previous `compose/` and `reapi-proxy/` trees into
`/var/lib/buildbarn/_backups/<timestamp>/` before overwriting. SSH in,
`rsync` them back, `docker compose up -d`.

**Debugging a worker from the central.**
Every `create-central.sh` run ensures the central has its own ed25519
keypair at `/root/.ssh/id_ed25519` and that its public key is registered
with Hetzner as the named SSH key `bb-psmdb-ondemand-central`. The
numeric id of that key is auto-appended to
`hcloud_ssh_key_ids` in the baked `ondemand-pools.yaml`, so every worker
the scaler (or `spawn-worker.sh`) spawns from that point on trusts the
central for SSH. A small wrapper lands on the central at
`/usr/local/bin/ssh-worker` with host-key-checking disabled (workers are
ephemeral and Hetzner recycles IPs):

```bash
ssh root@<central-public-ip>
ssh-worker <worker-private-ip>                          # interactive shell on a worker
ssh-worker <worker-private-ip> 'cd /opt/buildbarn && docker compose ps'
ssh-worker <worker-private-ip> 'docker compose logs --tail=100 runner worker'
```

Two caveats:

1. Workers spawned **before** the key was registered (or under a *previous*
   central keypair, e.g. if the central VM itself was replaced) are NOT
   SSH-reachable from the current central. Hetzner does not allow adding
   SSH keys to an already-created VM. Either wait for the idle-reap to
   replace them, or `hcloud server delete <worker-name>` them and let the
   scaler recreate under the new key.

2. The central's keypair survives volume detach/reattach (it lives on the
   boot disk, not the XFS volume). But `hcloud server delete` on the central
   destroys the keypair — the next `create-central.sh` generates a new one
   and rotates the Hetzner named key; all existing workers become
   unreachable from the new central. Plan worker rotation accordingly.

**Finding a historical build (bb-portal).**
`bb-scheduler-admin` (`:7982`) only shows operations that are still
queued/running or finished within the last minute — once a Bazel client
disconnects, the scheduler forgets about the operation. For post-mortem
investigation 30 min, 3 h, or 30 d after a build finished, use bb-portal
on `https://${PUBLIC_HOSTNAME}:7986/`.

Three common paths in:

```
1. Login                     →  https://${PUBLIC_HOSTNAME}:7986/
                                (302 to Dex → GitHub OAuth → team-gate)

2. By invocation ID          →  https://${PUBLIC_HOSTNAME}:7986/invocations/<INV>
                                (Bazel prints `INFO: Invocation ID: <UUID>` on
                                 every build; copy/paste that UUID here)

3. By Bazel error digest     →  bb-portal's "Action" tab on an invocation page
                                shows action stdout/stderr inline; you no
                                longer need to manually click into bb-browser
                                for blob lookups.
```

Sanity-check that BES ingest is actually working (do this after every
deploy, before relying on the data):

```bash
ssh root@${PUBLIC_HOSTNAME}
cd /var/lib/buildbarn/compose
# Recent BES events received?
docker compose logs --tail=50 bb-portal-backend | grep -i 'invocation\|bep'
# Database growing?
docker compose exec bb-portal-db \
  psql -U bbportal -d bbportal -c "SELECT count(*) FROM invocations WHERE created_at > now() - interval '1 day';"
```

If the second query returns 0 days after a deploy, suspect:
- Bazel clients aren't sending events (check `--bes_backend` in
  `.bazelrc.psmdb`; should be `grpcs://${PUBLIC_HOSTNAME}:1985`).
- Envoy is rejecting the JWT on `:1985` — `docker compose logs
  envoy-proxy | grep -i 'jwt\|1985'` will show 401s.
- bb-portal-db ran out of disk — `df /var/lib/buildbarn/portal-db`
  on the host. Default retention is 30 days (see
  `bb-portal.jsonnet::databaseCleanupConfiguration`); shrink to 7 d
  if you're on a tight volume.

**Backing up bb-portal-db (manual drill).**
This is build-telemetry, not source-of-truth data — losing it means
operators can't post-mortem old invocations, but daily Bazel work is
unaffected (BES events keep flowing into a freshly-empty database).
That makes a manual restore drill the right tool for now; cron-driven
backups are deferred (see "Future automation" below).

When you'd run this:
- Before a risky deploy that touches `bb-portal-db` config or the PDP
  image tag.
- Quarterly, as a "do I still know how" exercise.
- NOT as a replacement for replication or off-host backup — those
  remain out of scope for this iteration.

```bash
ssh root@${PUBLIC_HOSTNAME}
cd /var/lib/buildbarn/compose
ts=$(date +%Y%m%d-%H%M%S)
# Custom-format dump (-Fc): binary, compressed, restorable with
# pg_restore. Lives on the boot disk, NOT on the CAS volume — so a
# volume detach/reattach can't take the dump with it.
docker compose exec -T bb-portal-db \
  pg_dump -U bbportal -Fc bbportal \
  > /var/lib/buildbarn/portal-db-backup-${ts}.dump
ls -lh /var/lib/buildbarn/portal-db-backup-${ts}.dump
```

Restore drill (run on the central host, into a throwaway container so
production `bb-portal-db` stays untouched):

```bash
# Stand up a throwaway PG instance on a different port.
docker run --rm -d --name pg-restore-test \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=test \
  -p 5433:5432 percona/percona-distribution-postgresql:17.9
sleep 5
# Restore the dump into a fresh DB.
docker exec -i pg-restore-test \
  psql -U postgres -c 'CREATE DATABASE bbportal_restore_test;'
docker exec -i pg-restore-test \
  pg_restore -U postgres -d bbportal_restore_test \
  < /var/lib/buildbarn/portal-db-backup-${ts}.dump
# Sanity-check the row counts came across.
docker exec -i pg-restore-test \
  psql -U postgres -d bbportal_restore_test \
       -c 'SELECT count(*) FROM invocations;'
# Clean up.
docker rm -f pg-restore-test
rm /var/lib/buildbarn/portal-db-backup-${ts}.dump
```

If that count matches `SELECT count(*) FROM invocations` on the live
`bb-portal-db`, the drill passed.

**Future automation (deferred — nice-to-have).**
Daily/weekly cron-driven `pg_dump` to `/var/lib/buildbarn/backups/`
with retention rotation, plus optional off-host destination, plus a
matching restore probe in `create-central.sh::smoke()`, would turn
this manual drill into a real disaster-recovery posture. Tracked
separately from this plan; revisit when bb-portal becomes the
source-of-truth for "did build X pass" rather than just observability.
See [`../buildbarn-portal-plan.md`](../buildbarn-portal-plan.md)
§"Step 6 — Operator runbook" for the deferral note.

**Log rotation / retention.**
All BuildBarn services on this stack — including `bb-portal-db`,
`bb-portal-backend`, and `bb-portal-frontend` — inherit a
docker-native log rotation policy via the YAML anchor
`x-bb-image-common` in `compose/docker-compose.yml`:

```yaml
logging:
  driver: json-file
  options:
    max-size: "50m"
    max-file: "5"
```

Practical effect:
- Each container's stdout/stderr stream is capped at 5 rotated files
  of 50 MB each → **250 MB ceiling per container**.
- With ~9 long-running containers in the stack, the log footprint on
  the root disk tops out around 2.25 GB total, regardless of how
  long the central host has been running.
- Rotation happens automatically inside Docker — no cron, no
  external `logrotate`, no operator intervention needed.

Inspection commands (run on the central host):

```bash
ssh root@${PUBLIC_HOSTNAME}
cd /var/lib/buildbarn/compose
# Live tail one service.
docker compose logs -f --tail=200 bb-portal-backend
# All bb-portal services at once.
docker compose logs -f bb-portal-db bb-portal-backend bb-portal-frontend
# Search across the rotated files (Docker reads them transparently).
docker compose logs bb-portal-backend 2>&1 | grep -i 'error\|panic\|5[0-9][0-9]'
# Disk usage right now.
du -sh /var/lib/docker/containers/*/*-json.log* | sort -h | tail -10
```

What we deliberately don't do (today):
- **Off-host log shipping** to S3 / Loki / ELK — central host has
  no observability stack today; revisit if/when one lands (see
  `buildbarn-ondemand-scaler.md` §"Observability dashboard").
- **Long-term archival** beyond 250 MB-per-container — telemetry,
  not audit data; loss is acceptable.
- **Cron-driven `logrotate`** on `/var/lib/docker/containers/*` —
  redundant with `json-file` driver's built-in rotation; would only
  add monitoring surface (cron-failed alerts) for zero value.

If a panic / crash burst pushes useful evidence outside the 250 MB
window before you've grabbed it: bump `max-file` to `20` on the
specific service in `docker-compose.yml`, redeploy, reproduce. Don't
do that pre-emptively for the whole stack.

bb-portal does NOT replace `bb-browser` (`:7984`) or
`bb-scheduler-admin` (`:7982`) in Phase 1 — all three UIs answer in
parallel. Phase 2 collapses them; see
[`../buildbarn-portal-plan.md`](../buildbarn-portal-plan.md)
§"Phase 2 — Deprecation roadmap" for the conditions under which we'd
flip the switch.

## Spawning a worker (Phase 1, manual)

Once the central is up, you can bring up a single worker VM with:

```bash
POOL=ubuntu-noble-x86_64__v8_3__9873907c9659 \
  ./scripts/spawn-worker.sh
```

`POOL` must be a YAML key from
[`compose/config/ondemand-pools.yaml`](compose/config/ondemand-pools.yaml)
(naming convention is documented in that file's header). All other inputs —
`runner_image`, `bazel_pool_value`, `psmdb_version` — come from the YAML;
`spawn-worker.sh` reads them on startup and refuses to proceed if the
pool key isn't there.

Defaults (all overridable via env):

| Variable | Default | Purpose |
| -------- | ------- | ------- |
| `SERVER_TYPE` | `cpx42` | 8c shared / 16 GB / 320 GB disk — enough for one `--jobs=12` pool with ~100 GB hardlinking cache |
| `LOCATION` | `hel1` | same as the central so the private network works |
| `OS_IMAGE` | `debian-13` | matches the central's host OS |
| `NETWORK_ID` | (project-specific; live ID in `INFRASTRUCTURE.md` / `${HCLOUD_NETWORK_ID}`) | `psmdb.cd.percona.com` private net |
| `SSH_KEY_IDS` | `24333399 111196538` | both ops keys injected, same as central |
| `CENTRAL_NAME` | `bb-psmdb-ondemand` | discovered via `hcloud server describe` |
| `SERVER_NAME` | `bb-worker-<pool-slug>-${TS}` | underscores in pool name → hyphens, RFC 1123-safe |

Phase 1 VMs get a **public IPv4** so the operator can SSH in for debugging.
Phase 2 will drop that for workers spawned programmatically by the scaler.

What the script does:

1. **Preflight.** Local binaries, hcloud auth, SSH key, central reachable
   with a private IP on the expected network.
2. **Render.** Copies `worker/` into a staging dir, `sed`-replaces all
   `__CENTRAL_PRIVATE_IP__` / `__CENTRAL_PUBLIC_URL__` / `__POOL_NAME__` /
   `__WORKER_HOSTNAME__` / `__RUNNER_IMAGE__` placeholders. Refuses to
   proceed if any placeholder remains — that would ship broken configs.
3. **Create server.** `hcloud server create` with the rendered cloud-init
   as user-data and both SSH keys + the private network attached. Labels:
   `role=bb-worker project=psmdb-buildbarn pool=$POOL psmdb-version=<from-yaml>`
   (the `psmdb-version` value is read from the matched pool's
   `psmdb_version` field — `8.0` / `8.3` / `master`).
4. **Wait for SSH**, then `cloud-init status --wait`. If cloud-init fails,
   the tail of `/var/log/cloud-init-output.log` is printed and the script
   exits — the VM is left running for the operator to investigate.
5. **Deploy.** Rsyncs the rendered `worker/` tree into `/opt/buildbarn/` on
   the VM, then `docker compose pull && docker compose up -d`.
6. **Verify.** Polls `http://$CENTRAL_PUBLIC_IP:7982/` until the worker's
   hostname shows up on the scheduler admin page (or times out at ~60 s
   and prints a log command you can run to dig in).
7. **Summary.** SSH command, compose log cheat-sheet, and the `hcloud
   server delete` command to tear the VM back down.

**Tear down**:

```bash
hcloud server delete bb-worker-ubuntu-noble-x86_64-<timestamp>
```

Workers are stateless — everything under `/opt/buildbarn` on the VM
(including the ~100 GB hardlinking cache) is scratch and dies with the VM.

## Scaler (Phase 2 MVP)

A small Python daemon running on the central node, next to the rest of the
control plane. Every `poll_interval_seconds` (default 30 s) it:

1. Reads the scheduler's `BuildQueueState` gRPC at `127.0.0.1:8984` — each
   platform queue reports its queued operations and active-worker count.
2. Enumerates the Hetzner VMs it owns via the label
   `psmdb.managed-by=bb-ondemand-scaler`.
3. For every pool in [`compose/config/ondemand-pools.yaml`](compose/config/ondemand-pools.yaml),
   decides:
   - *scale up* — sizes the fleet from live queue pressure
     (`ceil((queued + executing) / concurrency)`, capped by `max_nodes` and
     `global.max_total_nodes`), with a default throttle of **1 new VM per
     pool per tick** so cold-starts proceed serially. Raise the throttle via
     the `SPAWN_THROTTLE_PER_POOL` env var when you want faster warm-up.
   - *scale down* — a managed VM has been idle for more than
     `scale_down_idle_seconds` (default 600 s)
4. Executes those decisions via `hcloud-python`, UNLESS `SCALER_DRY_RUN=true`
   (the default until the operator flips it off).

How workers are delivered: the scaler renders a **self-contained cloud-init**
that includes the entire `worker/` tree as `write_files` entries, so the VM
needs no outbound SSH from the scaler. Source of truth for both manual
(`spawn-worker.sh`) and automatic (`scaler.py`) paths is the same `worker/`
directory on the central.

### Dry-run → live workflow

```bash
# 1. After create-central.sh: scaler is already running in dry-run mode.
ssh root@$CENTRAL 'cd /var/lib/buildbarn/compose && docker compose logs -f scaler'
```

Expected output on an empty cluster:

```
scaler: tick: 0 platform queues, 0 managed VMs (dry_run=True)
```

Trigger a Bazel build from a client. You should see the queue appear and the
scaler log `[DRY_RUN] would spawn pool=ubuntu-noble-x86_64 queued=N`.

```bash
# 2. Once dry-run decisions look sane, go live:
ssh root@$CENTRAL bash <<'EOF'
  cd /var/lib/buildbarn/compose
  sed -i 's/^SCALER_DRY_RUN=true/SCALER_DRY_RUN=false/' .env
  docker compose up -d scaler
EOF
```

### Pool configuration

[`compose/config/ondemand-pools.yaml`](compose/config/ondemand-pools.yaml)
is the single knob you edit to add / remove / resize pools. The header in
that file documents the architecture, the pool naming convention, the
cross-release coexistence model, and the maintenance procedures (image
rebuild, PSMDB release EOL). Per-pool fields:

| Field | Purpose |
| ----- | ------- |
| `runner_image` | full ghcr.io URL with immutable `:<psmdb_version>-<git-sha>` tag, e.g. `ghcr.io/vorsel/psmdb-buildbarn-runners/ubuntu-noble-x86_64:8.0-9873907c…`. Single source of truth: docker compose pulls this, the routing key is `docker://<runner_image>`, and PSMDB fork's `bazel/platforms/psmdb_rbe_containers.bzl` must emit the same URL for handshake to work. `scripts/create-central.sh` auto-generates the matching `predeclaredPlatformQueues` entry at bake time |
| `bazel_pool_value` | value of Bazel's `Pool` platform property — `x86_64` or `aarch64`. Explicit per-pool rather than inferred from the pool name |
| `psmdb_version` | informational ("8.0" / "8.3" / "master") — used for the `psmdb.version` Hetzner label and log readability. Routing does NOT key off this field; routing keys off `runner_image` which encodes the version inside the immutable tag |
| `server_type` | `cpx42` default; bump to `cpx52` when we trust the config |
| `concurrency` | must match `worker.jsonnet`'s `runners[0].concurrency` |
| `min_nodes` / `max_nodes` | per-pool caps; a global cap lives under `global.max_total_nodes` |

The scaler **refuses to spawn** if `global.max_total_nodes` is reached, so
it can never cost-balloon beyond the hard cap set in the YAML.

### Running the scaler standalone (ops)

```bash
# On the central:
cd /var/lib/buildbarn/compose
docker compose up -d scaler
docker compose logs -f scaler
docker compose restart scaler      # after editing ondemand-pools.yaml
```

The scaler reloads config on restart (no SIGHUP handling in the MVP).

### Cold-start race (`FAILED_PRECONDITION`) and `predeclaredPlatformQueues`

Bazel's `GrpcRemoteExecutor` classifies `FAILED_PRECONDITION: No workers exist`
as a permanent error and never retries. With a naive setup, the first
`bazel build` against a cold scheduler dies on action #1 because the
scaler's 30 s poll + ~2 min VM boot runs **slower** than Bazel's first
`Execute` call.

Our answer is `predeclaredPlatformQueues` in `compose/config/scheduler.jsonnet`:
the scheduler creates each pool's queue at boot, independent of worker
registration. Bazel's `Execute` succeeds (action queues), the scaler sees
`queued > 0`, spawns a VM, and the action runs once the worker joins.
Bazel's default 3600 s `--remote_timeout` absorbs the wait.

**One source of truth.** `compose/config/ondemand-pools.yaml` is the only
file you edit. At deploy time, `scripts/create-central.sh` runs
`bake_predeclared()` which reads the YAML and generates
`compose/config/predeclared.libsonnet` — a small JSON array of
`PredeclaredPlatformQueueConfiguration` entries, one per pool. Each
entry's `container-image` property is `docker://<runner_image>` (taken
verbatim from the YAML's `runner_image` field). `scheduler.jsonnet`
imports that file. YAML and scheduler config stay in sync **by
construction** — there is nothing to drift. Hand-editing
`predeclared.libsonnet` is not supported; the file carries a
`// AUTO-GENERATED` header and is overwritten on every deploy.

**Where routing keys come from.** Each pool's `runner_image` is a Percona-
controlled immutable ghcr.io tag built by
`.github/workflows/build-psmdb-buildbarn-runners.yml`. The PSMDB-side
companion to this YAML is
[`bazel/platforms/psmdb_rbe_containers.bzl`](https://github.com/vorsel/percona-server-mongodb/blob/PSMDB-2034_psmdb_rbe_containers/bazel/platforms/psmdb_rbe_containers.bzl)
in the PSMDB fork: it pins the same image URLs (per release branch) and
overrides upstream MongoDB's `quay.io` map for distros Percona supports.
For a successful handshake the URLs must match byte-for-byte across
both files; a single git-sha bump in lockstep on both sides is the only
moving part.

**Maintenance** — see the procedures in the
[ondemand-pools.yaml header](compose/config/ondemand-pools.yaml). In
short: when GHA pushes a new immutable image generation, ops PRs the
new tags into both files and redeploys; old pool entries stay in this
YAML until the corresponding PSMDB release goes EOL, so multiple active
release tags (e.g. `release-8.0.20-8` and `release-8.0.21-9`) coexist
without cache-poisoning each other.

## Onboarding a PSMDB branch to RBE

Routing PSMDB Bazel actions to this RBE cluster requires changes in the
**`percona-server-mongodb` fork** (not in this repo). Per-branch state
diverges between `v8.0`, `v8.3`, and `master`, so each branch is patched
**individually** in agent mode rather than via a shared patch set — code in
`bazel/platforms/` and `bazel/wrapper_hook/` evolves between PSMDB releases
and not every change applies to every branch.

### Files modified per branch

| File | v8.0 | v8.3 | master | Purpose |
| ---- | ---- | ---- | ------ | ------- |
| `.bazelrc.psmdb` | yes | yes | yes | adds the `psmdb_buildfarm` config group (RBE endpoint, instance name, gRPC keepalive, spawn strategy). v8.3 and master also include `common:psmdb_buildfarm --//bazel/config:build_enterprise=False` defensively (see wrapper_hook row) — the file-wide `build --build_enterprise=False` line covers the legacy bool flag, but the Starlark flag wired through `--//bazel/config:` needs explicit pinning when the wrapper hook stops auto-injecting it |
| `bazel/platforms/psmdb_rbe_containers.bzl` (new) | yes | yes | yes | maps each supported `distro_or_os` to a `ghcr.io/vorsel/psmdb-buildbarn-runners` immutable tag. Per-branch `<version-prefix>-<git-sha>` ensures action-cache isolation between branches |
| `bazel/platforms/platform_util.bzl` | yes | yes | yes | overlays `PSMDB_REMOTE_EXECUTION_CONTAINERS` over upstream `REMOTE_EXECUTION_CONTAINERS` for explicit `//bazel/platforms:<distro>_<arch>` targets. v8.3/master variant is structurally different from v8.0 (no kernel-constraint logic) — patch is hand-adapted per branch |
| `bazel/platforms/local_config_platform.bzl` | yes | yes | yes | same overlay for the auto-generated host platform, so `bazel build` without `--platforms=` routes to the correct `ghcr.io` worker queue |
| `bazel/wrapper_hook/wrapper_hook.py` | **n/a** | yes | yes | the hook is a minimal passthrough on v8.0 (no `--config=local` auto-injection logic), but on v8.3 and master upstream extended it to auto-inject `--config=local` whenever `src/mongo/db/modules/enterprise` is missing — which is *always* true for PSMDB. That injection silently resets `--remote_executor` and `--remote_cache` to empty and forces a fully local build. Patch skips the auto-injection when `--config=psmdb_buildfarm` is on the command line. v8.0 needs no patch. **Verify before assuming**: `head -1 bazel/wrapper_hook/wrapper_hook.py` — if it starts with `import os` (v8.0-style), no patch needed; if it starts with `#!/usr/bin/env python3` and has an `enterprise_mod` check, patch is needed |

### Cache isolation between branches

The routing key Bazel sends is the full `docker://ghcr.io/...:<version-prefix>-<sha>`
URL. v8.0 builds emit `:8.0-<sha>`, v8.3 → `:8.3-<sha>`, master → `:master-<sha>`.
The version prefix is part of the platform property hashed into the action
digest, so **action-cache hits do not cross PSMDB release branches by
design**. First build on a freshly-onboarded branch is always 0% remote
cache hit; cache hits start showing on subsequent builds of the *same*
branch (and across release patches if the immutable tag's git-sha is held
constant — bumping the sha invalidates the cache deliberately).

### Closing PSMDB-2034: PRs to open

Once all three branches build green via `--config=psmdb_buildfarm`, open one
PR per branch against `vorsel/percona-server-mongodb`:

- [ ] `PSMDB-2034_psmdb_rbe_containers` → **`v8.0`**
- [ ] `PSMDB-2034_psmdb_rbe_containers__v8.3` → **`v8.3`**
- [ ] `PSMDB-2034_psmdb_rbe_containers__master` → **`master`**

Each PR body should link back to this README's "Onboarding a PSMDB branch
to RBE" section and to the corresponding successful Jenkins build summary
(actions ran, remote / local / internal split, wall time vs critical path).

## aarch64 worker support

Status: **enabled on all PSMDB versions** (v8.0, v8.3, master).

The GHA workflow `.github/workflows/build-psmdb-buildbarn-runners.yml`
publishes a multi-arch manifest list per `(distro, version, sha)`
(see "PSMDB-2034: refactor RBE runner workflow to multi-arch manifest
lists"), so each distro carries one tag that resolves to either the
amd64 or arm64 layer based on the worker's host arch. All three
PSMDB branches' `bazel/platforms/psmdb_rbe_containers.bzl` are pinned
to those multi-arch tags (`<distro>:<version>-9b28c6ee49dc...`, no
`-x86_64` suffix), and `compose/config/ondemand-pools.yaml` carries
5 aarch64 sibling pool entries per version (one per distro except
debian-bookworm — the GHA matrix excludes `debian-bookworm-aarch64`,
so its manifest list is amd64-only).

### Routing key

For both x86_64 and aarch64 sibling pools the
`container-image` routing key is byte-identical (same multi-arch URL).
The discriminator that picks between sibling pools is the `Pool` exec
property (`x86_64` vs `aarch64`), which both PSMDB Bazel and the
worker registration emit in lockstep. PSMDB
`bazel/platforms/{platform_util,local_config_platform}.bzl` sets
`Pool=aarch64` for arm64 hosts (upstream's default of `"default"` was
EngFlow-specific and would not match our worker queues).

### Hetzner CAX

Server type for aarch64 pools is `cax31` (8-core ARM Neoverse,
16 GB, 160 GB local, €0.0256/h) — Hetzner's ARM equivalent of
`cpx42`. Identical region availability (fsn1 / hel1 / nbg1) and
hourly cost.

### Wall-clock vs arch (default `CppLink=local`)

End-to-end `install-dist-test` builds against a freshly seeded
remote action cache (`bazel clean` + same `GIT_COMMIT_HASH`, no
local re-runs), GHA sha `9b28c6ee49dc`, `--jobs=130`. All numbers
captured with the default strategy
(`CppCompile=remote,local`, `CppLink=local`, `CppArchive=local`).

| PSMDB | Pool | Server | Cache | Wall | Critical path | Total / remote actions |
| ----- | ---- | ------ | ----- | ---- | ------------- | ---------------------- |
| `master` | `ubuntu-noble-x86_64` | `cpx42` | cold | **25:49** (1549 s) | 264 s | 18 209 / 10 439 |
| `master` | `ubuntu-noble-aarch64` | `cax31` | cold | **1:07:12** (3983 s) | 621 s | 18 202 / 10 432 |
| `v8.3` | `ubuntu-noble-aarch64` | `cax31` | cold | **1:03:24** (3804 s) | 567 s | 17 849 / 10 217 |
| `v8.3` | `ubuntu-noble-aarch64` | `cax31` | warm | **4:04** (244 s) | 72 s | 17 849 / 10 217 (cache hits) |

Take-aways:

- **arch is the dominant cold-cache factor**, not PSMDB version:
  master aarch64 is +5 % over v8.3 aarch64 (matches the +2 % action
  count delta + 9 % longer CP), while master x86_64 is **2.6×
  faster** than master aarch64 on identical action shape and same
  `cax31` ↔ `cpx42` price point. This is per-core CPU performance
  (Ampere Altra Neoverse-N1 vs AMD EPYC Zen 3 on a template-heavy
  C++ workload) — not a parallelism or scheduler issue.
- **Warm cache flattens the gap**: 17 849/17 849 actions resolve as
  cache hits, and the build becomes I/O+network bound. Expect master
  aarch64 warm to land within ±20 s of the v8.3 aarch64 warm row;
  warm runs are mostly downloading and unpacking remote outputs,
  where ARM and AMD perform similarly.
- **For the same wall-time goal on aarch64**, two knobs exist
  (neither configured today):
  1. `cax41` (16-core ARM, 32 GB) instead of `cax31` — same
     ~€0.0512/h, doubles the per-worker concurrency.
  2. More `cax31` pool slots — same `--jobs=130` from the client,
     more workers absorb the action graph.
  Both shorten wall time on cold cache; neither changes warm cache
  numbers, which are already network/IO bound.

### CppLink strategy: keep `local` (measured)

Default and only supported strategy for PSMDB Jenkins jobs:

```
--strategy=CppCompile=remote,local \
--strategy=CppLink=local \
--strategy=CppArchive=local
```

Measured on the ubuntu-noble aarch64 v8.0 pool (`cax31`, 8-core ARM
Neoverse, GHA sha `9b28c6ee49dc`, `--jobs=130`, `install-dist-test`):

| Strategy | Warm cache | Cold cache | Δ critical path |
| -------- | ---------- | ---------- | --------------- |
| `CppLink=local` | **13–14 min** (788–838 s, CP 746–763 s) | **~34 min** (2031 s, CP 1497 s) | baseline |
| `CppLink=remote` | ~21 min (1274 s, CP 1231 s) | ~49 min (2943 s, CP 2276 s) | **+60–65% warm, +52% cold** |

Warm-cache row averages **two** consecutive runs (different
`GIT_COMMIT_HASH`, same input set, fully populated remote cache);
cold-cache row is **one** `bazel clean` + full build with the action
cache pre-warmed. `CP` = Bazel-reported critical path; the
wall-clock range on warm captures the natural run-to-run variance
on `cax31`. Numbers will move when the runner image bumps to a new
GHA sha (compiler / sysroot bytes change → action digests change →
remote cache miss until that sha re-warms).

Why remote linking is *slower* here:

- Link actions are short (~1–3 s locally on `cax31`); remote overhead
  per action (input `.o`/`.a` upload, queue wait, output `.so`
  download) is 5–20 s. With ~1325 link actions, that overhead
  dominates wall time even at `--jobs=130` parallelism.
- `CppArchive` is unconditional `local` (1315 actions; same fixed
  cost in both columns). Remote-linking only moves the *other*
  ~1325 link actions off-host, so the win is bounded by half the
  archive/link total at best — and gets fully consumed by per-action
  network overhead.
- Bazel's link-phase action graph is heavily serialised by library
  dependency chains (low-level libs → high-level libs → final
  binaries). Local link keeps the gap between waves at 1–3 s; remote
  link blows it up to 5–20 s, which compounds across the chain.

#### Known limitation: `coefficient` exec_property breaks `CppLink=remote`

Upstream MongoDB's `bazel/mongo_src_rules.bzl` injects a
`cpp_link.coefficient` exec_property on every link action (e.g. `"18.0"`
when `compress_debug_compile=True` — our default; `"3.0"` otherwise),
and a `cpp_link.cpus` exec_property when `thin_lto` or `bolt` is
enabled (currently neither is in `psmdb_buildfarm`). Bazel strips the
`cpp_link.` prefix and ships the bare `coefficient` / `cpus` properties
to the RBE scheduler. EngFlow uses these for resource accounting;
**bb-scheduler does not** — its
[`PlatformKeyExtractorConfiguration`](https://github.com/buildbarn/bb-remote-execution/blob/master/pkg/proto/configuration/scheduler/scheduler.proto)
does only EXACT match against `predeclaredPlatformQueues`, so the
extra property turns the routing key into something that has no
matching queue, and `Execute` fails:

```
FAILED_PRECONDITION: No workers exist for instance name prefix "hardlinking" platform
  {"properties":[{"name":"Pool","value":"aarch64"},
                 {"name":"coefficient","value":"18.0"},
                 {"name":"container-image","value":"docker://..."},
                 {"name":"dockerNetwork","value":"standard"}]}
```

If you see this error in any future re-evaluation of remote linking,
the platform JSON in the message will tell you which extra property
landed in the routing key. Three documented workarounds, in order of
preference if/when remote linking ever stops being a measured loss
(see table above):

1. **Patch upstream MongoDB rules** (`bazel/mongo_src_rules.bzl`) in
   the PSMDB fork to drop the `cpp_link.coefficient` /
   `cpp_link.cpus` exec_properties under `--config=psmdb_buildfarm`.
   Smallest blast radius — single file, single repo, scheduler
   config stays untouched.
2. **Demultiplexing actionRouter** in `scheduler.jsonnet` —
   `DemultiplexingActionRouter` with one backend per
   `(pool, coefficient, cpus)` combination, each forwarding to a
   sub-router whose `static` `PlatformKeyExtractor` rewrites the
   routing key back to the canonical 3-property tuple. **Caveat**:
   bb-scheduler's `platform.Trie` is `map[platform_json_string]→…`,
   so backend matching is EXACT on the platform's canonical JSON,
   not subset / longest-prefix on properties. To cover all 23 pools
   you'd need 23 × N backends (N = number of distinct
   `coefficient` × `cpus` combinations the build emits).
   `bake_predeclared()` would have to learn to enumerate them.
   Adds a 3rd source-of-truth for the immutable image SHA on top of
   `psmdb_rbe_containers.bzl` and `ondemand-pools.yaml`.
3. **Fork `bb-remote-execution`** to add a property-filter
   `PlatformKeyExtractor` (drop a configurable allowlist of
   exec_properties before forming the routing key). Cleanest from
   an architecture standpoint, highest maintenance burden — we'd
   ship a forked scheduler image.

We tried (2) for the `ubuntu-noble-aarch64__v8_0` pool as a
spike — it works, but contains `--strategy=CppLink=remote` to one
pool out of 23 (others still hit the same `FAILED_PRECONDITION`)
and requires keeping the image SHA in lockstep across three files.
Combined with the measurement above (remote linking is *slower*),
the cost-benefit didn't justify keeping it. If link=remote ever
becomes a net win (e.g. `mold` / `lld` with the sysroot prebaked
into the runner image, or 16-core build hosts shifting the local
linker bottleneck), revisit option (1) first — it's an order of
magnitude smaller change than (2) and removes the `coefficient`
issue at the source instead of routing around it.

### AWS Graviton fallback (PoC)

When `cax31` is exhausted in every Hetzner region (the recurring
hours-long aarch64 hang — §11.1), the scaler can fall back to AWS
Graviton (`c7g`) workers that reach the central over a WireGuard
tunnel. Disabled by default (`aws.enabled: false`). Design, prereqs,
and setup runbook: [`../aws-graviton-fallback.md`](../aws-graviton-fallback.md).
Stand up the hub with [`scripts/setup-wireguard-hub.sh`](scripts/setup-wireguard-hub.sh).

### Follow-ups still open

- [ ] If GHA capacity for `cax31` becomes a bottleneck, generalise
  the scaler's region round-robin to a `(server_type, region)`
  round-robin so a stuck `cax31` order can fall back to
  `cax21` / `cax41` (and then to AWS — see the Graviton fallback above).
- [ ] If we ever need debian-bookworm on arm64, add a
  `debian-bookworm-aarch64` source dir + matrix entry in the GHA
  workflow first; the manifest list will then carry both arches and
  a sibling pool can be added without further Bazel-side changes.

## What's *not* here yet

| Future component | Status | Lives in |
| ---------------- | ------ | -------- |
| Pre-warm HTTP API (Jenkins hints before a release matrix) | post-MVP | `scaler/scaler.py` |
| Snapshot-based fast boot (~40 s instead of ~120 s) | post-MVP | Hetzner snapshots |
| FUSE-mode worker (more efficient than hardlinking, needs `privileged: true`) | post-MVP | `ondemand/worker/` |
| Prometheus `/metrics` endpoint on the scaler | post-MVP | `scaler/scaler.py` |

Design and milestones in [`../buildbarn-ondemand-scaler.md`](../buildbarn-ondemand-scaler.md).
