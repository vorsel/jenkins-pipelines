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
│   │                                  browser + reapi-proxy + envoy-proxy
│   ├── .env.example                ← copy to .env; bootstrap script writes
│   │                                  the real .env for you
│   └── config/
│       ├── common.libsonnet        ← shared blobstore / browserUrl
│       ├── storage.jsonnet         ← 369 GB per shard (sized for 750 GB vol)
│       ├── scheduler.jsonnet       ← admin :7982, client :8982, worker :8983,
│       │                             buildQueueState :8984
│       ├── frontend.jsonnet        ← gRPC :8980 (internal)
│       ├── browser.jsonnet         ← HTTP :7984
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
| Hetzner private network | `11374636` — `psmdb.cd.percona.com` | Workers and Bazel clients live here |
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
ssh-worker 10.30.242.10                          # interactive shell on a worker
ssh-worker 10.30.242.10 'cd /opt/buildbarn && docker compose ps'
ssh-worker 10.30.242.10 'docker compose logs --tail=100 runner worker'
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
| `NETWORK_ID` | `11374636` | `psmdb.cd.percona.com` private net |
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

## What's *not* here yet

| Future component | Status | Lives in |
| ---------------- | ------ | -------- |
| Pre-warm HTTP API (Jenkins hints before a release matrix) | post-MVP | `scaler/scaler.py` |
| Snapshot-based fast boot (~40 s instead of ~120 s) | post-MVP | Hetzner snapshots |
| FUSE-mode worker (more efficient than hardlinking, needs `privileged: true`) | post-MVP | `ondemand/worker/` |
| Prometheus `/metrics` endpoint on the scaler | post-MVP | `scaler/scaler.py` |

Design and milestones in [`../buildbarn-ondemand-scaler.md`](../buildbarn-ondemand-scaler.md).
