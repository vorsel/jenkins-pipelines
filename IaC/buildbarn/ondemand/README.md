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
└── scripts/
    └── create-central.sh           ← the one-shot bootstrap / adopt tool

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

## What's *not* here yet

| Future component | Status | Lives in |
| ---------------- | ------ | -------- |
| `spawn-worker.sh` — manual worker VM creation | to do (Phase 1) | `ondemand/scripts/` |
| `scaler/` — the daemon that watches `BuildQueueState` and manages VMs | to do (Phase 2) | `ondemand/scaler/` |
| `ondemand-pools.yaml` — per-`(distro, arch)` pool definitions | to do (Phase 2) | `ondemand/` |

Design and milestones in [`../buildbarn-ondemand-scaler.md`](../buildbarn-ondemand-scaler.md).
