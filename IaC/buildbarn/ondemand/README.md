# `bb-psmdb-ondemand` — BuildBarn control plane for ephemeral workers

Green-field BuildBarn deployment that runs **only the control plane** on a
single permanent Hetzner Cloud VM. Workers are ephemeral: an external scaler
(not yet implemented — see [`buildbarn-ondemand-scaler.md`](../buildbarn-ondemand-scaler.md))
spins Hetzner VMs up when `(distro, arch)` work is queued and tears them down
after an idle timeout.

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
│       └── browser.jsonnet         ← HTTP :7984
├── worker/                         ← template for an ondemand bb-worker VM
│   ├── cloud-init.yml.tmpl         ← Debian 13 + Docker + sysctl tuning
│   ├── docker-compose.yml          ← runner-installer + bb-worker + pool runner
│   └── config/
│       ├── common.libsonnet        ← blobstore → central's envoy; browserUrl
│       ├── worker.jsonnet          ← scheduler addr, concurrency, platform
│       └── runner.jsonnet          ← unix-socket runner (verbatim from prod)
└── scripts/
    ├── create-central.sh           ← one-shot bootstrap / adopt of the central
    └── spawn-worker.sh             ← create a single ondemand worker VM

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

## Spawning a worker (Phase 1, manual)

Once the central is up, you can bring up a single worker VM with:

```bash
POOL=ubuntu-noble-x86_64 PSMDB_VERSION=8.3 \
  ./scripts/spawn-worker.sh
```

Defaults (all overridable via env):

| Variable | Default | Purpose |
| -------- | ------- | ------- |
| `SERVER_TYPE` | `cpx42` | 8c shared / 16 GB / 320 GB disk — enough for one `--jobs=12` pool with ~100 GB hardlinking cache |
| `LOCATION` | `hel1` | same as the central so the private network works |
| `OS_IMAGE` | `debian-13` | matches the central's host OS |
| `NETWORK_ID` | `11374636` | `psmdb.cd.percona.com` private net |
| `SSH_KEY_IDS` | `24333399 111196538` | both ops keys injected, same as central |
| `RUNNER_REGISTRY` | `ghcr.io/vorsel/psmdb-buildbarn-runners` | anonymous pull |
| `RUNNER_IMAGE` | `${RUNNER_REGISTRY}/${POOL}:${PSMDB_VERSION}` | what the runner container runs |
| `CENTRAL_NAME` | `bb-psmdb-ondemand` | discovered via `hcloud server describe` |
| `SERVER_NAME` | `bb-worker-${POOL}-${TS}` | must be unique per run |

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
   as user-data and both SSH keys + the private network attached. Labels
   `role=bb-worker project=psmdb-buildbarn pool=$POOL psmdb-version=$PSMDB_VERSION`.
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

## What's *not* here yet

| Future component | Status | Lives in |
| ---------------- | ------ | -------- |
| `scaler/` — the daemon that watches `BuildQueueState` and manages VMs | to do (Phase 2) | `ondemand/scaler/` |
| `ondemand-pools.yaml` — per-`(distro, arch)` pool definitions | to do (Phase 2) | `ondemand/` |
| FUSE-mode worker (more efficient than hardlinking, needs `privileged: true`) | post-Phase-2 | `ondemand/worker/` |
| Snapshot-based fast boot (~40 s instead of ~120 s) | post-Phase-2 | Hetzner snapshots |

Design and milestones in [`../buildbarn-ondemand-scaler.md`](../buildbarn-ondemand-scaler.md).
