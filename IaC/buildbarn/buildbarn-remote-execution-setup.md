# BuildBarn: Remote Execution & Cache for Bazel

## Overview

BuildBarn is an open-source (Apache 2.0) remote execution and caching system for Bazel. It allows build actions to be executed on a remote server and caches results across developers and CI pipelines.

**Repository:** https://github.com/buildbarn/bb-deployments

## Server Requirements

- **OS:** Ubuntu 24.04 LTS (or any Linux with Docker support)
- **Recommended minimum:** 16 CPU, 32 GB RAM, 100 GB+ disk
- **Tested on:** Hetzner Cloud CPX62 (16 shared vCPU, 32 GB RAM, 640 GB disk)

## Part 1: Server Setup

### 1.1 Install Docker

```bash
curl -fsSL https://get.docker.com | sh
```

If not running as root, add your user to the docker group:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

### 1.2 Install Bazelisk

Bazelisk is a lightweight launcher that automatically downloads the correct Bazel version.

```bash
curl -fsSL https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64 -o /usr/local/bin/bazel
chmod +x /usr/local/bin/bazel
```

Verify:

```bash
bazel --version
```

### 1.3 Install gcc/g++

Bazel requires a local C compiler for toolchain detection during the analysis phase, even when all actions run remotely.

```bash
apt install -y gcc g++
```

### 1.4 Clone and Start BuildBarn

```bash
git clone https://github.com/buildbarn/bb-deployments.git
cd bb-deployments/docker-compose
./run.sh
```

The `run.sh` script creates the necessary volume directories and runs `docker compose up`.

To run in the background (detached mode):

```bash
./run.sh -d
```

> **Note:** During the first 5–10 seconds, the worker container may log `connection refused` errors. This is expected — it starts before the scheduler is ready. The errors will stop once all services are up.

### 1.5 Verify All Containers Are Running

```bash
docker compose ps
```

All containers should show status `Up`:

| Container | Role |
|---|---|
| `frontend` | gRPC endpoint for Bazel (port 8980) |
| `storage-0`, `storage-1` | Sharded CAS/AC storage |
| `scheduler` | Action scheduler |
| `worker-fuse-ubuntu22-04` | FUSE-based worker (may not work on shared VPS) |
| `worker-hardlinking-ubuntu22-04` | Hardlinking worker (always works) |
| `runner-fuse-ubuntu22-04` | Action executor for FUSE worker (Ubuntu 22.04) |
| `runner-hardlinking-ubuntu22-04` | Action executor for hardlinking worker (Ubuntu 22.04) |
| `runner-installer` | Installs the `bb_runner` binary |
| `browser` | Web UI for inspecting artifacts (port 7984) |

### 1.6 FUSE Worker on Shared VPS

On shared VPS instances (e.g. Hetzner CPX), the FUSE worker typically **does not work** due to kernel restrictions. You will see errors like:

```
Failed to invalidate "..." in root directory: 9=bad file descriptor
```

This is not a problem. Use the **hardlinking worker** instead by specifying `--remote_instance_name=hardlinking` in all Bazel commands. The hardlinking worker is functionally identical — it only differs in how it manages files on disk (hardlinks instead of FUSE mounts).

To check FUSE worker status:

```bash
docker compose logs worker-fuse-ubuntu22-04 2>&1 | tail -10
```

### 1.7 Adjust Worker Concurrency

By default, the hardlinking worker runs with `concurrency: 8`. This should be adjusted to ~75% of available CPU cores to leave headroom for storage, scheduler, and frontend services.

Calculate the recommended value:

```bash
echo $(( $(nproc) * 75 / 100 ))
```

Edit `~/bb-deployments/docker-compose/config/worker-hardlinking-ubuntu22-04.jsonnet` and update the `concurrency` field:

```jsonnet
runners: [{
    endpoint: { address: 'unix:///worker/runner' },
    concurrency: 12,  // adjust to: nproc * 75 / 100
```

Then restart BuildBarn:

```bash
cd ~/bb-deployments/docker-compose
docker compose down
./run.sh -d
```

### 1.8 Tune Central Storage (required for PSMDB)

The stock `bb-deployments` storage config ships with tiny CAS/AC blocks (~32 GB CAS, ~20 MB AC). For PSMDB the MongoDB toolchain alone is several GB, and each action produces metadata. Default sizes cause:

- **CAS eviction under load** — toolchain blobs get evicted mid-build, workers re-fetch them, fetch time explodes
- **AC churn** — action cache hits drop across builds because old entries roll off quickly

Increase sizes in `~/bb-deployments/docker-compose/config/storage.jsonnet`:

| Store | Field | Stock default | PSMDB value |
|-------|-------|---------------|-------------|
| CAS | `blocks.sizeBytes` | ~32 GB | **200 GB** |
| CAS | `key_location_map.sizeBytes` | ~400 MB | **4 GB** |
| CAS | `newBlocks` | 1 | **3** |
| AC | `blocks.sizeBytes` | ~20 MB | **2 GB** |
| AC | `key_location_map.sizeBytes` | ~1 MB | **50 MB** |
| FSAC | `blocks.sizeBytes` | ~20 MB | **2 GB** |
| FSAC | `key_location_map.sizeBytes` | ~1 MB | **50 MB** |

Block layout is the same across all three stores: `oldBlocks: 8`, `currentBlocks: 24`, `spareBlocks: 3`. CAS uses `newBlocks: 3`, AC/FSAC use `newBlocks: 1`.

Final config (CAS section, AC/FSAC follow the same pattern with smaller sizes):

```jsonnet
contentAddressableStorage: {
  backend: {
    'local': {
      keyLocationMapOnBlockDevice: {
        file: {
          path: '/storage-cas/key_location_map',
          sizeBytes: 4 * 1024 * 1024 * 1024,           // 4 GB
        },
      },
      keyLocationMapMaximumGetAttempts: 16,
      keyLocationMapMaximumPutAttempts: 64,
      oldBlocks: 8,
      currentBlocks: 24,
      newBlocks: 3,
      blocksOnBlockDevice: {
        source: {
          file: {
            path: '/storage-cas/blocks',
            sizeBytes: 200 * 1024 * 1024 * 1024,       // 200 GB
          },
        },
        spareBlocks: 3,
      },
      persistent: {
        stateDirectoryPath: '/storage-cas/persistent_state',
        minimumEpochInterval: '300s',
      },
    },
  },
  getAuthorizer: { allow: {} },
  putAuthorizer: { allow: {} },
  findMissingAuthorizer: { allow: {} },
},
```

> **Disk requirements.** BuildBarn runs two storage shards (`storage-0`, `storage-1`); each one holds its own copy of CAS + AC + FSAC. With the values above that's `(200 + 2 + 2) GB ≈ 204 GB per shard ≈ 408 GB` total for the two shards on the central server. Ensure the Docker volumes for `storage-0` and `storage-1` live on a disk with headroom (≥500 GB recommended).

> **Changing `sizeBytes` wipes existing storage.** After editing, remove the old block-device files and let BuildBarn recreate them on startup:
>
> ```bash
> cd ~/bb-deployments/docker-compose
> docker compose down
> sudo rm -rf volumes/storage-{0,1}/*
> ./run.sh -d
> ```
>
> Do this **before** running a large warm-cache build so you don't throw away valuable cache entries.

Restart to apply:

```bash
cd ~/bb-deployments/docker-compose
docker compose down
./run.sh -d
```

## Part 2: Ports and Access

After startup, the following ports are available:

| Port | Service | Purpose |
|------|---------|---------|
| 8980 | frontend (gRPC) | Bazel endpoint (`--remote_executor`, `--remote_cache`) |
| 7984 | bb-browser (HTTP) | Web UI for inspecting CAS/AC artifacts |
| 7982 | scheduler admin (HTTP) | Scheduler admin panel |

Verify that port 8980 is listening on all interfaces:

```bash
ss -tlnp | grep 8980
# Expected: 0.0.0.0:8980 (NOT 127.0.0.1:8980)
```

If `ufw` is active, open the required ports:

```bash
ufw allow 8980/tcp
ufw allow 7984/tcp
```

### 2.1 Update browserUrl for Remote Access

By default, BuildBarn generates bb-browser links pointing to `localhost:7984`. These links appear in Bazel error messages for failed actions and in the scheduler admin UI. To make them work from other machines, update the `browserUrl` in the configuration:

Edit `~/bb-deployments/docker-compose/config/common.libsonnet`:

```diff
- browserUrl: 'http://localhost:7984',
+ browserUrl: 'http://YOUR_SERVER_IP:7984',
```

Then restart BuildBarn:

```bash
cd ~/bb-deployments/docker-compose
docker compose down
./run.sh -d
```

After this change:
- **Scheduler admin UI** (`http://YOUR_SERVER_IP:7982`) — shows queued and active operations
- **bb-browser** (`http://YOUR_SERVER_IP:7984`) — links from failed action errors will be clickable from any machine

## Part 3: Testing on the Server

### 3.1 Test Remote Execution

```bash
cd ~/bb-deployments
bazel build \
    --config=remote-ubuntu-22-04 \
    --remote_instance_name=hardlinking \
    @abseil-hello//:hello_main
```

Expected output:

```
INFO: 32 processes: 3 action cache hit, 1 internal, 31 remote.
INFO: Build completed successfully, 32 total actions
```

`31 remote` confirms that actions were executed on the BuildBarn worker.

### 3.2 Test Remote Cache

Clean the local Bazel cache and rebuild:

```bash
bazel clean
bazel build \
    --config=remote-ubuntu-22-04 \
    --remote_instance_name=hardlinking \
    @abseil-hello//:hello_main
```

Expected output:

```
INFO: 35 processes: 31 remote cache hit, 4 internal.
INFO: Build completed successfully, 35 total actions
```

`31 remote cache hit` confirms that cached results are being reused from BuildBarn storage.

## Part 4: Testing from a Remote Machine

### 4.1 From a Docker Container

Launch an Ubuntu container on any machine with network access to the server:

```bash
docker run -it --rm ubuntu:24.04 bash
```

Inside the container:

```bash
# Install dependencies
apt update && apt install -y curl gcc g++ git

# Install Bazelisk
curl -fsSL https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64 -o /usr/local/bin/bazel
chmod +x /usr/local/bin/bazel

# Create a test project
mkdir /tmp/bb-test && cd /tmp/bb-test

cat > MODULE.bazel << 'EOF'
module(name = "bb-test")
EOF

cat > BUILD << 'EOF'
genrule(
    name = "hello",
    outs = ["hello.txt"],
    cmd = "echo 'Hello from BuildBarn remote execution!' > $@",
)
EOF

# Build via remote execution (replace YOUR_SERVER_IP with the actual IP)
bazel build //:hello \
    --remote_executor=grpc://YOUR_SERVER_IP:8980 \
    --remote_instance_name=hardlinking \
    --remote_default_exec_properties=OSFamily=linux \
    --remote_default_exec_properties='container-image=docker://ghcr.io/catthehacker/ubuntu:act-22.04@sha256:dd7654ffb01d5b7b54b23b9ce928a1f7f2d08c7b3d7e320b6574b55d7ccde78b'

# Verify
cat bazel-bin/hello.txt
# Output: Hello from BuildBarn remote execution!
```

Expected Bazel output:

```
INFO: 2 processes: 1 internal, 1 remote.
INFO: Build completed successfully, 2 total actions
```

### 4.2 Stress Test from a Remote Machine

To verify that remote execution handles real workloads, build multiple abseil-cpp libraries from a Docker container on a different machine:

```bash
docker run -it --rm ubuntu:24.04 bash
```

Inside the container:

```bash
apt update && apt install -y curl gcc g++ git

curl -fsSL https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64 -o /usr/local/bin/bazel
chmod +x /usr/local/bin/bazel

git clone https://github.com/buildbarn/bb-deployments.git
cd bb-deployments

# Build 30+ abseil-cpp targets with all transitive dependencies (replace YOUR_SERVER_IP)
bazel build \
    --config=remote-ubuntu-22-04 \
    --remote_instance_name=hardlinking \
    --remote_executor=grpc://YOUR_SERVER_IP:8980 \
    --keep_going \
    @abseil-cpp//absl/strings \
    @abseil-cpp//absl/strings:cord \
    @abseil-cpp//absl/container:flat_hash_map \
    @abseil-cpp//absl/container:flat_hash_set \
    @abseil-cpp//absl/container:btree \
    @abseil-cpp//absl/container:node_hash_map \
    @abseil-cpp//absl/container:inlined_vector \
    @abseil-cpp//absl/base \
    @abseil-cpp//absl/base:core_headers \
    @abseil-cpp//absl/hash \
    @abseil-cpp//absl/time \
    @abseil-cpp//absl/synchronization \
    @abseil-cpp//absl/debugging:stacktrace \
    @abseil-cpp//absl/debugging:symbolize \
    @abseil-cpp//absl/numeric:int128 \
    @abseil-cpp//absl/memory \
    @abseil-cpp//absl/algorithm \
    @abseil-cpp//absl/status \
    @abseil-cpp//absl/status:statusor \
    @abseil-cpp//absl/types:span \
    @abseil-cpp//absl/types:optional \
    @abseil-cpp//absl/types:variant \
    @abseil-cpp//absl/log \
    @abseil-cpp//absl/log:check \
    @abseil-cpp//absl/flags:flag \
    @abseil-cpp//absl/flags:parse \
    @abseil-cpp//absl/functional:any_invocable \
    @abseil-cpp//absl/functional:function_ref \
    @abseil-cpp//absl/cleanup \
    @abseil-cpp//absl/crc:crc32c \
    @abseil-cpp//absl/random
```

Expected output (approximately):

```
INFO: 169 processes: 28 remote cache hit, 1 internal, 140 remote.
INFO: Build completed successfully, 169 total actions
```

> **Note:** Use `--keep_going` to skip any targets that fail due to missing benchmark dependencies. The `@abseil-cpp//...` wildcard pattern cannot be used directly because abseil-cpp benchmark targets require `@google_benchmark` which is not included in bb-deployments.

### 4.3 Integration with an Existing Project

Add the following to your project's `.bazelrc.local`:

```
--config=buildbarn
common:buildbarn --remote_executor=grpc://YOUR_SERVER_IP:8980
common:buildbarn --remote_cache=grpc://YOUR_SERVER_IP:8980
common:buildbarn --remote_instance_name=hardlinking
common:buildbarn --remote_default_exec_properties=OSFamily=linux
common:buildbarn --remote_default_exec_properties=container-image=docker://ghcr.io/catthehacker/ubuntu:act-22.04@sha256:dd7654ffb01d5b7b54b23b9ce928a1f7f2d08c7b3d7e320b6574b55d7ccde78b
common:buildbarn --jobs=64
```

Then build with:

```bash
bazel build --config=buildbarn //your:target
```

> **Note:** Projects that override `--remote_executor`, `--bes_backend`, `--remote_cache`, or TLS settings in their `.bazelrc` may need additional overrides in the `buildbarn` config block to clear those values (e.g. `--bes_backend=`, `--tls_client_certificate=`).

## Part 5: Adding Worker Nodes

Worker nodes only need Docker and 3 containers (worker, runner, runner-installer). They connect to the central scheduler over the private network. No storage, scheduler, frontend, or browser needed.

### Prerequisites

- Docker installed on the worker node
- Private network connectivity to the central server (e.g. Hetzner Cloud Network)

Verify connectivity from the worker node:

```bash
# Ping the central server via private network
ping -c 3 SCHEDULER_PRIVATE_IP

# Verify scheduler and frontend ports are reachable
timeout 3 bash -c 'echo > /dev/tcp/SCHEDULER_PRIVATE_IP/8983 && echo "scheduler OK"' 2>/dev/null || echo "scheduler FAIL"
timeout 3 bash -c 'echo > /dev/tcp/SCHEDULER_PRIVATE_IP/8980 && echo "frontend OK"' 2>/dev/null || echo "frontend FAIL"
```

### 5.1 Create Directory Structure

```bash
mkdir -p /opt/buildbarn/{config,volumes/bb}
mkdir -m 0777 /opt/buildbarn/volumes/worker /opt/buildbarn/volumes/worker/{build,cache}
chmod 0700 /opt/buildbarn/volumes/worker/cache
```

### 5.2 Worker Configuration

Create `/opt/buildbarn/config/worker.jsonnet`. Adjust `SCHEDULER_PRIVATE_IP`, `CENTRAL_SERVER_PUBLIC_IP`, `concurrency`, and `hostname` for each node.

Use all available CPU cores for worker-only nodes (no storage/scheduler overhead):

```bash
echo "Available CPUs: $(nproc)"
```

```bash
cat > /opt/buildbarn/config/worker.jsonnet << 'WORKER'
{
  blobstore: {
    contentAddressableStorage: {
      grpc: { client: { address: 'SCHEDULER_PRIVATE_IP:8980' } },
    },
    actionCache: {
      completenessChecking: {
        backend: {
          grpc: { client: { address: 'SCHEDULER_PRIVATE_IP:8980' } },
        },
        maximumTotalTreeSizeBytes: 64 * 1024 * 1024,
      },
    },
  },
  browserUrl: 'http://CENTRAL_SERVER_PUBLIC_IP:7984',
  maximumMessageSizeBytes: 2 * 1024 * 1024,
  scheduler: { address: 'SCHEDULER_PRIVATE_IP:8983' },
  global: {
    diagnosticsHttpServer: {
      httpServers: [{
        listenAddresses: [':80'],
        authenticationPolicy: { allow: {} },
      }],
      enablePrometheus: true,
      enablePprof: true,
      enableActiveSpans: true,
    },
  },
  buildDirectories: [{
    native: {
      buildDirectoryPath: '/worker/build',
      cacheDirectoryPath: '/worker/cache',
      maximumCacheFileCount: 1000000,
      maximumCacheSizeBytes: 100 * 1024 * 1024 * 1024,
      cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
    },
    runners: [{
      endpoint: { address: 'unix:///worker/runner' },
      concurrency: 16,  // set to nproc of this node
      instanceNamePrefix: 'hardlinking',
      platform: {
        properties: [
          { name: 'OSFamily', value: 'linux' },
          { name: 'container-image', value: 'docker://ghcr.io/catthehacker/ubuntu:act-22.04@sha256:dd7654ffb01d5b7b54b23b9ce928a1f7f2d08c7b3d7e320b6574b55d7ccde78b' },
        ],
      },
      workerId: {
        datacenter: 'hetzner',
        rack: '1',
        slot: '2',         // unique per node
        hostname: 'worker-1',  // unique per node
      },
    }],
  }],
  inputDownloadConcurrency: 10,
  outputUploadConcurrency: 11,
  directoryCache: {
    maximumCount: 1000,
    maximumSizeBytes: 1000 * 1024,
    cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
  },
}
WORKER
```

> **Important:** Replace `SCHEDULER_PRIVATE_IP` and `CENTRAL_SERVER_PUBLIC_IP` with actual IPs. Set `concurrency` to `nproc` of the node.

> **Worker local cache (critical for PSMDB).** The defaults in BuildBarn examples are `maximumCacheFileCount: 10000` and `maximumCacheSizeBytes: 1 GB` — far too small for MongoDB's toolchain (several GB). With the default cache, every action re-downloads the toolchain from central CAS, inflating input fetch from ~5 s to ~85 s per action. For PSMDB use:
>
> ```jsonnet
>   native: {
>     buildDirectoryPath: '/worker/build',
>     cacheDirectoryPath: '/worker/cache',
>     maximumCacheFileCount: 1000000,
>     maximumCacheSizeBytes: 100 * 1024 * 1024 * 1024,  // 100 GB
>     cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
>   },
> ```
>
> This requires that `/worker/cache` is on a disk with at least ~120 GB free. The cache is warmed by the first build; subsequent builds hit hardlinks instead of downloads.

> **`workerId` must be unique per node.** Change `slot` and `hostname` for every new worker:
>
> | Node | slot | hostname |
> |------|------|----------|
> | Central server | `"15"` | (set in jsonnet template) |
> | Worker node 1 | `"2"` | `"worker-1"` |
> | Worker node 2 | `"3"` | `"worker-2"` |
> | Worker node 3 | `"4"` | `"worker-3"` |
> | Worker node N | `"N+1"` | `"worker-N"` |
>
> If two workers register with the same `workerId`, the scheduler will treat them as one and actions will fail.

### 5.3 Runner Configuration

```bash
cat > /opt/buildbarn/config/runner.jsonnet << 'RUNNER'
{
  buildDirectoryPath: '/worker/build',
  grpcServers: [{
    listenPaths: ['/worker/runner'],
    authenticationPolicy: { allow: {} },
  }],
  global: {
    diagnosticsHttpServer: {
      httpServers: [{
        listenAddresses: [':81'],
        authenticationPolicy: { allow: {} },
      }],
      enablePrometheus: true,
      enablePprof: true,
      enableActiveSpans: true,
    },
  },
}
RUNNER
```

### 5.4 Docker Compose

> **For PSMDB:** Use `psmdb-runner:latest` instead of the default catthehacker image, and omit `network_mode: none`. See Part 8.5 for building the custom image. The example below shows the **generic** (non-PSMDB) configuration.

```bash
cat > /opt/buildbarn/docker-compose.yml << 'COMPOSE'
services:
  runner-installer:
    image: ghcr.io/buildbarn/bb-runner-installer:20260326T163248Z-e6ab874
    volumes:
      - bb:/bb

  worker:
    image: ghcr.io/buildbarn/bb-worker:20260326T163248Z-e6ab874
    command: ["/config/worker.jsonnet"]
    volumes:
      - ./config:/config
      - ./volumes/worker:/worker
    depends_on:
      - runner-installer

  runner:
    image: ghcr.io/catthehacker/ubuntu:act-22.04@sha256:dd7654ffb01d5b7b54b23b9ce928a1f7f2d08c7b3d7e320b6574b55d7ccde78b
    command:
      - sh
      - -c
      - while ! test -f /bb/installed; do sleep 1; done; exec /bb/bb_runner /config/runner.jsonnet
    network_mode: none
    volumes:
      - ./config:/config
      - bb:/bb
      - ./volumes/worker:/worker
    depends_on:
      - runner-installer

volumes:
  bb:
COMPOSE
```

**PSMDB variant** (custom runner image, no network isolation):

```bash
cat > /opt/buildbarn/docker-compose.yml << 'COMPOSE'
services:
  runner-installer:
    image: ghcr.io/buildbarn/bb-runner-installer:20260326T163248Z-e6ab874
    volumes:
      - bb:/bb

  worker:
    image: ghcr.io/buildbarn/bb-worker:20260326T163248Z-e6ab874
    command: ["/config/worker.jsonnet"]
    volumes:
      - ./config:/config
      - ./volumes/worker:/worker
    depends_on:
      - runner-installer

  runner:
    image: psmdb-runner:latest
    command:
      - sh
      - -c
      - while ! test -f /bb/installed; do sleep 1; done; exec /bb/bb_runner /config/runner.jsonnet
    volumes:
      - ./config:/config
      - bb:/bb
      - ./volumes/worker:/worker
    depends_on:
      - runner-installer

volumes:
  bb:
COMPOSE
```

### 5.5 Start and Verify

```bash
cd /opt/buildbarn
docker compose up -d

# Wait 10 seconds for containers to initialize
sleep 10

# Verify containers are running
docker compose ps -a

# Runner-installer should show Exited (0)
# Worker and runner should show Up
```

The worker logs will be empty when idle (no errors = good). To verify the worker is connected, run a build from the central server and monitor worker logs:

```bash
# On the worker node:
docker compose logs -f worker
```

When actions are dispatched to this worker, you will see log entries with action URLs and execution metadata.

### Required Ports on Central Server

Ensure these ports are accessible from the private network on the central server:

| Port | Service | Already open? |
|------|---------|---------------|
| 8980 | frontend (gRPC) | Yes (Bazel endpoint) |
| 8983 | scheduler (worker gRPC) | Yes (worker registration) |

## Part 6: Operations

### Restart Central Server

```bash
cd ~/bb-deployments/docker-compose
docker compose down
./run.sh
```

### Restart Worker Node

```bash
cd /opt/buildbarn
docker compose down
docker compose up -d
```

### View Logs

```bash
# Central server
cd ~/bb-deployments/docker-compose
docker compose logs -f scheduler
docker compose logs -f worker-hardlinking-ubuntu22-04
docker compose logs -f frontend

# Worker node
cd /opt/buildbarn
docker compose logs -f worker
```

### Stop All

```bash
# Central server
cd ~/bb-deployments/docker-compose
docker compose down

# Each worker node
cd /opt/buildbarn
docker compose down
```

## Architecture

### Generic BuildBarn

```
Bazel Client
    │
    ▼ (gRPC :8980)
┌──────────┐     ┌───────────┐     ┌───────────┐
│ Frontend │────▶│ Storage-0 │     │ Storage-1 │
│  (proxy) │────▶│ (CAS/AC)  │     │ (CAS/AC)  │
└────┬─────┘     └───────────┘     └───────────┘
     │
     ▼ (gRPC :8982)
┌───────────┐
│ Scheduler │
└─────┬─────┘
      │ (gRPC :8983)
      ▼
┌────────┐     ┌────────┐
│ Worker │────▶│ Runner │  (Ubuntu 22.04, network: none)
└────────┘     └────────┘
```

### With REAPI v2.0 Proxy (for PSMDB)

```
Bazel Client (PSMDB, REAPI v2.0)
    │
    ▼ (gRPC :8981)
┌─────────────────┐
│  Envoy Proxy    │
│  (gRPC router)  │
└──┬──────────┬───┘
   │          │
   │ Capabilities    All other RPCs
   │ RPCs            │
   ▼                 ▼
┌──────────┐    ┌──────────┐     ┌───────────┐     ┌───────────┐
│  REAPI   │    │ Frontend │────▶│ Storage-0 │     │ Storage-1 │
│  Proxy   │───▶│  (gRPC)  │────▶│ (CAS/AC)  │     │ (CAS/AC)  │
│ (Go,8990)│    │  (:8980) │     └───────────┘     └───────────┘
└──────────┘    └────┬─────┘
 patches low         │
 api_version         ▼ (gRPC :8982)
 2.3→2.0        ┌───────────┐
                │ Scheduler │
                └─────┬─────┘
                      │ (gRPC :8983)
                      ├─────────────────────┐
                      ▼                     ▼
                ┌────────┐            ┌────────┐
                │ Worker │            │ Worker │  (worker node)
                │(central)│           │(remote)│
                └───┬────┘            └───┬────┘
                    ▼                     ▼
                ┌────────┐            ┌────────┐
                │ Runner │            │ Runner │
                │(MongoDB│            │(MongoDB│
                │ image) │            │ image) │
                └────────┘            └────────┘
```

- **Frontend** — receives requests from Bazel, shards them across storage nodes
- **Storage** — stores CAS (Content Addressable Storage) and AC (Action Cache)
- **Scheduler** — distributes actions to available workers
- **Worker** — manages build directories, communicates with the scheduler
- **Runner** — isolated container where build commands are actually executed (no network access)
- **Envoy Proxy** — gRPC router, splits Capabilities RPCs from all other traffic
- **REAPI Proxy** — Go service that patches `GetCapabilities` response, changing `LowApiVersion` from 2.3 to 2.0

## Part 7: REAPI v2.0 Compatibility Proxy (for PSMDB)

### Problem

Percona Server for MongoDB (PSMDB) uses MongoDB's pinned Bazel fork — currently **`bazel release 7.5.0-mongo_06d753863d`** (`bazel --version` output) — which speaks **REAPI v2.0 only** even though upstream Bazel 7.x speaks 2.3+. BuildBarn requires **REAPI v2.3+**. During the `GetCapabilities` handshake, Bazel sees the server's `LowApiVersion=2.3` and rejects it:

```
ERROR: The client supported API versions, 2.0 to 2.0, is not supported by the server, 2.3 to 2.12.
```

Standard Bazel (8.x, 9.x) cannot build PSMDB — the project is tightly coupled to MongoDB's Bazel fork (custom rules, `cc_binary` extensions, toolchain definitions).

### Solution

A transparent gRPC proxy sitting in front of BuildBarn:

1. **Envoy** (port 8981) — routes `Capabilities` RPCs to the patching proxy, everything else directly to BuildBarn frontend (port 8980)
2. **Go REAPI Proxy** (port 8990) — fetches real capabilities from BuildBarn, patches `LowApiVersion` and `DeprecatedApiVersion` to `2.0.0`, returns the modified response

All other RPCs (Execute, WaitExecution, FindMissingBlobs, etc.) go directly to BuildBarn unmodified. The actual REAPI wire format between v2.0 and v2.3 is compatible for execution and caching — only the capability negotiation check fails.

### 7.1 Proxy Source Code

All proxy files live in `barn/reapi-proxy/` relative to the PSMDB repository root.

**`main.go`** — Go gRPC service that intercepts and patches `GetCapabilities`:

```go
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"

	remoteexecution "github.com/bazelbuild/remote-apis/build/bazel/remote/execution/v2"
	semver "github.com/bazelbuild/remote-apis/build/bazel/semver"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/reflection"
)

var (
	listenAddr  = flag.String("listen", ":8990", "listen address for capabilities proxy")
	backendAddr = flag.String("backend", "frontend:8980", "BuildBarn frontend address")
)

type capServer struct {
	remoteexecution.UnimplementedCapabilitiesServer
	client remoteexecution.CapabilitiesClient
}

func (s *capServer) GetCapabilities(ctx context.Context, req *remoteexecution.GetCapabilitiesRequest) (*remoteexecution.ServerCapabilities, error) {
	resp, err := s.client.GetCapabilities(ctx, req)
	if err != nil {
		return nil, err
	}

	original := "unknown"
	if resp.LowApiVersion != nil {
		original = formatVer(resp.LowApiVersion)
	}

	resp.DeprecatedApiVersion = &semver.SemVer{Major: 2, Minor: 0, Patch: 0}
	resp.LowApiVersion = &semver.SemVer{Major: 2, Minor: 0, Patch: 0}

	log.Printf("Patched capabilities for %q: low %s -> 2.0.0, high=%s",
		req.InstanceName, original, formatVer(resp.HighApiVersion))
	return resp, nil
}

func formatVer(v *semver.SemVer) string {
	if v == nil {
		return "nil"
	}
	return fmt.Sprintf("%d.%d.%d", v.Major, v.Minor, v.Patch)
}

func main() {
	flag.Parse()

	conn, err := grpc.NewClient(*backendAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(64*1024*1024)),
	)
	if err != nil {
		log.Fatalf("connect to backend %s: %v", *backendAddr, err)
	}
	defer conn.Close()

	srv := grpc.NewServer()
	remoteexecution.RegisterCapabilitiesServer(srv, &capServer{
		client: remoteexecution.NewCapabilitiesClient(conn),
	})
	reflection.Register(srv)

	lis, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		log.Fatalf("listen %s: %v", *listenAddr, err)
	}
	log.Printf("REAPI capabilities proxy: %s -> %s (patching low_api_version to 2.0.0)", *listenAddr, *backendAddr)
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
```

**`go.mod`**:

```
module reapi-capabilities-proxy

go 1.24

require (
	github.com/bazelbuild/remote-apis v0.0.0-20260216160025-715b73f3f9e4
	google.golang.org/grpc v1.68.1
	google.golang.org/protobuf v1.35.2
)
```

> **Note:** `go.sum` is generated automatically by `go mod tidy` during Docker build.

**`Dockerfile`**:

```dockerfile
FROM golang:1.24-alpine AS builder
RUN apk add --no-cache git
WORKDIR /app
COPY go.mod main.go ./
RUN go mod tidy && go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /reapi-proxy .

FROM alpine:3.20
COPY --from=builder /reapi-proxy /usr/local/bin/reapi-proxy
ENTRYPOINT ["reapi-proxy"]
```

**`envoy.yaml`** — routes `Capabilities` RPCs to the Go proxy, everything else to BuildBarn:

```yaml
static_resources:
  listeners:
  - name: grpc_listener
    address:
      socket_address:
        address: 0.0.0.0
        port_value: 8981
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: reapi_proxy
          codec_type: AUTO
          http2_protocol_options:
            max_concurrent_streams: 1000
            initial_stream_window_size: 1048576
            initial_connection_window_size: 1048576
          route_config:
            name: local_route
            virtual_hosts:
            - name: reapi
              domains: ["*"]
              routes:
              - match:
                  prefix: "/build.bazel.remote.execution.v2.Capabilities/"
                route:
                  cluster: capabilities_proxy
                  timeout: 30s
              - match:
                  prefix: "/"
                route:
                  cluster: buildbarn_frontend
                  timeout: 3600s
                  max_stream_duration:
                    grpc_timeout_header_max: 3600s
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:
  - name: capabilities_proxy
    connect_timeout: 5s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        explicit_http_config:
          http2_protocol_options: {}
    load_assignment:
      cluster_name: capabilities_proxy
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: reapi-proxy
                port_value: 8990

  - name: buildbarn_frontend
    connect_timeout: 5s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        explicit_http_config:
          http2_protocol_options:
            max_concurrent_streams: 1000
    load_assignment:
      cluster_name: buildbarn_frontend
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: frontend
                port_value: 8980
```

**`docker-compose.yml`**:

```yaml
services:
  reapi-proxy:
    build:
      context: .
      dockerfile: Dockerfile
    command: ["-listen", ":8990", "-backend", "frontend:8980"]
    networks:
      - docker-compose_default
    restart: always

  envoy-proxy:
    image: envoyproxy/envoy:v1.31-latest
    command: ["envoy", "-c", "/etc/envoy/envoy.yaml", "--log-level", "warn"]
    volumes:
      - ./envoy.yaml:/etc/envoy/envoy.yaml:ro
    ports:
      - "8981:8981"
    networks:
      - docker-compose_default
    depends_on:
      - reapi-proxy
    restart: always

networks:
  docker-compose_default:
    external: true
```

> **Note:** The `docker-compose_default` network name must match the network created by the main BuildBarn `docker-compose.yml`. Verify with `docker network ls | grep compose`.

### 7.2 Deploy the Proxy

On the central server (where BuildBarn runs):

```bash
# Copy the barn/reapi-proxy/ directory to the server
scp -r barn/reapi-proxy/ root@YOUR_SERVER_IP:~/reapi-proxy/

# Build and start
cd ~/reapi-proxy
docker compose up -d --build

# Verify both containers are running
docker compose ps
# reapi-proxy    Up
# envoy-proxy    Up (port 8981)

# Check proxy logs
docker compose logs reapi-proxy
# "REAPI capabilities proxy: :8990 -> frontend:8980 (patching low_api_version to 2.0.0)"
```

Open port 8981 in the firewall:

```bash
ufw allow 8981/tcp
```

### 7.3 Verify the Proxy

From any machine with `grpcurl`:

```bash
grpcurl -plaintext YOUR_SERVER_IP:8981 \
  build.bazel.remote.execution.v2.Capabilities/GetCapabilities
```

The response should show `"major": 2` in `lowApiVersion` (not 2.3).

## Part 8: PSMDB-Specific Worker Configuration

### Problem

PSMDB's Bazel build sends specific platform properties with every remote execution request:

```json
{
  "properties": [
    {"name": "Pool", "value": "x86_64"},
    {"name": "container-image", "value": "docker://quay.io/mongodb/bazel-remote-execution@sha256:f1bd96104b3b8d33fff1500421917f3e15d9525795043e8d3f7f382e87c10002"},
    {"name": "dockerNetwork", "value": "standard"}
  ]
}
```

BuildBarn requires **exact match** of platform properties between what the client sends and what the worker advertises. Both the set of properties and their values must be identical.

Additionally, BuildBarn requires platform properties to be **lexicographically sorted by name**. `container-image` must come before `dockerNetwork` (c < d).

### 8.1 Central Server Worker Config

Edit `~/bb-deployments/docker-compose/config/worker-hardlinking-ubuntu22-04.jsonnet`:

```jsonnet
      platform: {
        properties: [
          { name: 'Pool', value: 'x86_64' },
          { name: 'container-image', value: 'docker://quay.io/mongodb/bazel-remote-execution@sha256:f1bd96104b3b8d33fff1500421917f3e15d9525795043e8d3f7f382e87c10002' },
          { name: 'dockerNetwork', value: 'standard' },
        ],
      },
```

> **Important:** Do NOT include `OSFamily=linux` — PSMDB does not send it, and BuildBarn requires exact match. Adding extra properties will cause "No workers exist" errors.

### 8.2 Worker Node Config

Edit `/opt/buildbarn/config/worker.jsonnet` on each worker node with the same platform properties:

```jsonnet
      platform: {
        properties: [
          { name: 'Pool', value: 'x86_64' },
          { name: 'container-image', value: 'docker://quay.io/mongodb/bazel-remote-execution@sha256:f1bd96104b3b8d33fff1500421917f3e15d9525795043e8d3f7f382e87c10002' },
          { name: 'dockerNetwork', value: 'standard' },
        ],
      },
```

### 8.3 Runner Container Image

PSMDB's MongoDB toolchain (`mongo_toolchain_v5`) requires **GLIBC 2.38+**. The default BuildBarn runner image (`catthehacker/ubuntu:act-22.04`) has GLIBC 2.35 (Ubuntu 22.04), which causes:

```
external/mongo_toolchain_v5/v5/bin/gcc: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found
```

Replace the runner image in `docker-compose.yml` with the MongoDB remote execution image (Ubuntu 24.04, GLIBC 2.39):

**Central server** (`~/bb-deployments/docker-compose/docker-compose.yml`):

Change only the `runner-hardlinking-ubuntu22-04` service image from:

```
ghcr.io/catthehacker/ubuntu:act-22.04@sha256:dd7654ffb01d5b7b54b23b9ce928a1f7f2d08c7b3d7e320b6574b55d7ccde78b
```

to:

```
quay.io/mongodb/bazel-remote-execution@sha256:f1bd96104b3b8d33fff1500421917f3e15d9525795043e8d3f7f382e87c10002
```

Do NOT change the `runner-fuse-ubuntu22-04` image.

**Worker node** (`/opt/buildbarn/docker-compose.yml`):

Change the `runner` service image to the same MongoDB image.

### 8.4 Runner Network Access (`network_mode`)

By default, BuildBarn runners use `network_mode: none` for security isolation. PSMDB builds require internet access in the runner for Python wheel downloads (`pip install pymongo`, `ct3`, etc.), so this must be disabled.

**Central server** (`~/bb-deployments/docker-compose/docker-compose.yml`):

Comment out `network_mode: none` for `runner-hardlinking-ubuntu22-04` only (do NOT change `runner-fuse-ubuntu22-04`):

```bash
# Find the line number
grep -n "network_mode" ~/bb-deployments/docker-compose/docker-compose.yml
# Identify which line belongs to runner-hardlinking (not runner-fuse)
# Comment it out:
sed -i 'LINE_NUMBERs/^/#/' ~/bb-deployments/docker-compose/docker-compose.yml
```

**Worker node** (`/opt/buildbarn/docker-compose.yml`):

Same — comment out or remove `network_mode: none` from the runner service.

> **Security note:** This gives the runner container full network access. For production, consider pre-populating Python wheels or using a network-restricted approach.

### 8.5 Custom Runner Image with Dev Packages

The MongoDB remote execution image does not include all `-dev` packages required for compilation. Build a custom image on each node.

Create `Dockerfile`:

```bash
mkdir -p /opt/buildbarn/runner-image

cat > /opt/buildbarn/runner-image/Dockerfile << 'EOF'
FROM quay.io/mongodb/bazel-remote-execution@sha256:f1bd96104b3b8d33fff1500421917f3e15d9525795043e8d3f7f382e87c10002

RUN apt-get update && apt-get install -y \
    zlib1g-dev libext2fs-dev libssl-dev libcurl4-openssl-dev \
    liblzma-dev libsasl2-dev libbz2-dev libkrb5-dev \
    libldap2-dev liblz4-dev \
    && rm -rf /var/lib/apt/lists/*
EOF
```

Build:

```bash
docker build -t psmdb-runner:latest /opt/buildbarn/runner-image/
```

Then replace the runner image in `docker-compose.yml`:

```bash
sed -i 's|quay.io/mongodb/bazel-remote-execution@sha256:f1bd96104b3b8d33fff1500421917f3e15d9525795043e8d3f7f382e87c10002|psmdb-runner:latest|' /opt/buildbarn/docker-compose.yml
```

**Central server** (`~/bb-deployments/docker-compose/docker-compose.yml`):

Same — build the image and replace only the `runner-hardlinking-ubuntu22-04` image (not `runner-fuse-ubuntu22-04`):

```bash
mkdir -p ~/bb-runner-custom
# Copy the same Dockerfile
cat > ~/bb-runner-custom/Dockerfile << 'EOF'
FROM quay.io/mongodb/bazel-remote-execution@sha256:f1bd96104b3b8d33fff1500421917f3e15d9525795043e8d3f7f382e87c10002

RUN apt-get update && apt-get install -y \
    zlib1g-dev libext2fs-dev libssl-dev libcurl4-openssl-dev \
    liblzma-dev libsasl2-dev libbz2-dev libkrb5-dev \
    libldap2-dev liblz4-dev \
    && rm -rf /var/lib/apt/lists/*
EOF

docker build -t psmdb-runner:latest ~/bb-runner-custom/

# Replace only the hardlinking runner image (line 119 typically)
# Verify which line to change:
grep -n "quay.io/mongodb\|psmdb-runner\|catthehacker" ~/bb-deployments/docker-compose/docker-compose.yml
# Then replace
sed -i 's|quay.io/mongodb/bazel-remote-execution@sha256:f1bd96104b3b8d33fff1500421917f3e15d9525795043e8d3f7f382e87c10002|psmdb-runner:latest|' ~/bb-deployments/docker-compose/docker-compose.yml
```

This image must be built on **every node** (it is local-only, not pushed to a registry).

### 8.6 Restart After Configuration Changes

After modifying worker config and runner image:

```bash
# Central server
cd ~/bb-deployments/docker-compose
docker compose down && docker compose up -d

# Each worker node
cd /opt/buildbarn
docker compose down && docker compose up -d
```

Verify workers registered without errors:

```bash
# Central server
docker compose logs worker-hardlinking-ubuntu22-04 --tail 10 --since 2m
# Empty output = good (no errors)

# Worker node
docker compose logs worker --tail 10 --since 2m
```

## Part 9: PSMDB Build Client Configuration

### 9.1 How PSMDB's Bazel Configuration Works

PSMDB has a layered Bazel configuration that affects remote execution:

1. **`.bazelrc`** — main config. On line 562: bare `--config=local` (always applied). `common:local` clears `--remote_executor`, `--remote_cache`, sets `--grpc_keepalive_time=0s`
2. **`.bazelrc.psmdb`** — imported by `.bazelrc`, explicitly disables remote execution/cache (`--remote_executor=`, `--remote_cache=`, `--grpc_keepalive_time=0s`)
3. **`.bazelrc.wrapper_hook`** — MongoDB's Bazel wrapper script that auto-injects `--config=local`
4. **`.bazelrc.local`** — **loaded last**, overrides everything above. This is where we inject BuildBarn settings

**Critical:** Because `--config=local` is always applied and its expansion happens **after** all rc files are loaded, we must use **`common:local`** (not bare `common`) in `.bazelrc.local` to override the local config's empty values.

PSMDB's build rules define their own `exec_properties` for C++ actions:
- `Pool=x86_64`
- `container-image=docker://quay.io/mongodb/bazel-remote-execution@sha256:...`
- `dockerNetwork=standard`

These override `--remote_default_exec_properties` from `.bazelrc.local`. The `--remote_default_exec_properties` only apply to actions that don't specify their own properties (e.g., genrules, Python wheel downloads).

### 9.2 Build Client Setup

Install dependencies on the build client machine (Ubuntu 24.04):

```bash
# System packages
apt update && apt install -y software-properties-common
add-apt-repository -y ppa:deadsnakes/ppa
apt update && apt install -y \
  curl gcc g++ git \
  python3.13 python3.13-venv python3.13-dev \
  zlib1g-dev libssl-dev libcurl4-openssl-dev liblzma-dev \
  libext2fs-dev libsasl2-dev libbz2-dev libkrb5-dev \
  libldap2-dev liblz4-dev

update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.13 1

# Clone PSMDB
git clone https://github.com/percona/percona-server-mongodb.git
cd percona-server-mongodb

# Install MongoDB's custom Bazel fork (NOT standard bazelisk)
python3 buildscripts/install_bazel.py
export PATH="$HOME/.local/bin:$PATH"
bazel --version
# Expected output: bazel release 7.5.0-mongo_06d753863d
```

> **Important:** PSMDB requires MongoDB's custom Bazel fork. Standard Bazelisk or upstream Bazel will fail with `cc_binary` rule errors. The fork is installed via `buildscripts/install_bazel.py` which downloads the correct binary from MongoDB's S3 bucket.

#### Bazel version pinning

| Component | Version |
|-----------|---------|
| Bazel binary | **`7.5.0-mongo_06d753863d`** (MongoDB fork of upstream Bazel 7.5.0) |
| Source of truth | `buildscripts/install_bazel.py` in PSMDB repo (which mirrors MongoDB's `mongo` repo Bazel pin) |
| REAPI version spoken by client | **2.0** (despite Bazel 7.5.0 normally speaking 2.3+) |
| Why 2.0 | The MongoDB fork forces the REAPI version down to 2.0; this is the reason we need the REAPI v2.0 capabilities proxy described in Part 7 |

Practical implications when reading Bazel docs / debugging:

- Most Bazel 7.x flags work as-documented (e.g. `--remote_retries`, `--noremote_accept_cached`, `--profile`, `--execution_log_compact_file`).
- A handful of post-7.x flag renames are **not** present (e.g. `--remote_retry_max_attempts` does not exist; use `--remote_retries=N` instead).
- `--config=psmdb_dev` is defined in PSMDB's checked-in `.bazelrc` and pulls in MongoDB-specific toolchain selection. It is **always required** for PSMDB builds.
- The wrapper hook script (`.bazelrc.wrapper_hook`, see §9.2) injects `--config=local` automatically — that is what activates the BuildBarn flags from `.bazelrc.local`.

### 9.3 `.bazelrc.local`

Create `.bazelrc.local` in the PSMDB repository root. All flags use **`common:local`** to override the always-applied `--config=local`:

```bash
cat > .bazelrc.local << 'EOF'
common:local --remote_executor=grpc://YOUR_SERVER_IP:8981
common:local --remote_cache=grpc://YOUR_SERVER_IP:8981
common:local --remote_instance_name=hardlinking
common:local --remote_upload_local_results=true
common:local --remote_timeout=10m
common:local --remote_cache_compression=false
common:local --grpc_keepalive_time=30s
common:local --jobs=64
EOF
```

Key details:
- **Port 8981** — Envoy proxy (REAPI v2.0 compatibility), NOT 8980 (direct BuildBarn)
- **`common:local`** — overrides `--config=local` which `.bazelrc` always applies
- **`--grpc_keepalive_time=30s`** — required because `.bazelrc.psmdb` sets it to `0s`, which causes "keepalive time must be positive" error when remote executor is active
- **`--remote_cache_compression=false`** — BuildBarn does not support zstd compression

### 9.4 Build Command

```bash
bazel build --config=psmdb_dev \
  --spawn_strategy=remote,local \
  --strategy=CppCompile=remote,local \
  --strategy=CppLink=local \
  --strategy=CppArchive=local \
  --define=MONGO_VERSION=8.3.0-0 \
  --define=GIT_COMMIT_HASH=$(git rev-parse HEAD) \
  --keep_going \
  --jobs=96 \
  --profile=/tmp/psmdb-profile.json.gz \
  install-mongod
```

> **Do not use `--execution_log_json_file` on large targets** (e.g. `install-dist-test`, 18k actions). Bazel buffers the full log in memory and throws `java.lang.OutOfMemoryError: Java heap space` **after** the build completes. Use `--execution_log_compact_file=/tmp/exec-log.binpb.zst` (binary proto, streamed) if you need the log, otherwise drop the flag entirely.

Strategy breakdown:
- `--spawn_strategy=remote,local` — default for all actions: try remote first, fall back to local
- `CppCompile=remote,local` — compile remotely, fall back to local if remote fails
- `CppLink=local` — linking is kept local (large memory footprint, requires all object files locally)
- `CppArchive=local` — archive creation local
- `--keep_going` — continue building other targets when some fail

> **Note:** When a remote action fails (e.g., missing library on worker), `remote,local` does NOT automatically retry locally. The fallback only applies when the remote service is unreachable. Failed actions are reported as errors.

### 9.5 Understanding Build Output

During the build, Bazel shows action status:

```
[2,941 / 9,445] 64 actions, 28 running
    Compiling src/mongo/db/query/util/disjoint_set.cpp; 35s remote, remote-cache
```

- `2,941 / 9,445` — completed / total actions
- `64 actions, 28 running` — 64 dispatched, 28 actively executing on workers
- `remote, remote-cache` — this action ran on a remote worker with cache enabled
- `local` — ran on the client machine

Final summary:

```
INFO: Elapsed time: 3994.456s, Critical Path: 367.13s
INFO: 3217 processes: 35 remote cache hit, 732 internal, 368 local, 2082 remote.
INFO: Build completed successfully, 3217 total actions
```

- `remote` — executed on BuildBarn workers (2082 = 65% of all actions)
- `remote cache hit` — result fetched from BuildBarn cache without re-execution
- `internal` — Bazel internal actions (no execution needed)
- `local` — executed on the client machine (linking, archives)
- `Elapsed time` — wall clock time
- `Critical Path` — longest sequential chain of actions (theoretical minimum even with infinite workers)

### 9.6 Concurrency and Performance

Build speed depends on **total worker concurrency** — the sum of `concurrency` values across all worker nodes. This controls how many build actions execute in parallel.

```
concurrency in worker config = max parallel gcc/g++ processes on that node
```

Guidelines:
- **Central server** (shared with scheduler/storage/frontend): set to `nproc * 75 / 100` to leave headroom for storage and the frontend
- **Dedicated worker nodes**: start at `nproc` (100% of cores) as a baseline
- **Oversubscription (`nproc × 1.3`–`1.5`)** can help when remote actions spend significant wall time on input fetch / output upload (I/O-bound slots free cores). Current PSMDB deployment runs dedicated workers at `nproc × 1.5` (24 slots on 16 cores) — safe because each compile averages 4.6 s fetch + 16 s CPU, so ~30% of wall time is I/O-waiting
- Pure CPU-bound workloads (large warm worker cache, no fetch) can thrash under oversubscription — measure before committing

| Setup | Total concurrency | Notes |
|-------|-------------------|-------|
| 1 server, 16 cores | 12 | Baseline, central-only |
| 1 server + 1 worker (16 cores each) | 12 + 16 = 28 | Worker at `nproc` |
| 1 server + 2 workers (16 cores each, ×1.5 oversubscribed) | 12 + 24 + 24 = 60 | **Current PSMDB setup** |
| 1 server + 3 workers (16 cores each) | 12 + 48 = 60 | `nproc` on each worker |

Bazel's `--jobs` flag controls how many actions Bazel sends to the scheduler. Set it higher than total concurrency (e.g., `--jobs=96`) so the scheduler always has work queued.

### 9.7 Build Results

Results on a 3-node setup (central + 2 dedicated workers, 60 total worker concurrency, Bazel `--jobs=96`) after tuning worker cache (`maximumCacheSizeBytes=100GB`, `maximumCacheFileCount=1000000`) and central storage sizes.

**`install-mongod` — cold remote cache** (first build, default small caches):

```
INFO: Elapsed time: 3994.456s, Critical Path: 367.13s
INFO: 3217 processes: 35 remote cache hit, 732 internal, 368 local, 2082 remote.
```

Wall time ~67 min, 2082 actions executed remotely.

**`install-dist-test` — cold remote cache, tuned worker cache** (after `bazel clean`):

```
INFO: Elapsed time: 1786.840s, Critical Path: 287.51s
INFO: 17991 processes: 5888 internal, 1773 local, 10330 remote.
```

Wall time **~30 min** (5888 internal + 10330 remote + 1773 local). Compared to ~3 hours for a local build on a 16-core client machine.

**`install-dist-test` — warm remote cache** (`bazel clean` on client, CAS/AC already populated):

```
INFO: Elapsed time: 167.472s, Critical Path: 48.27s
INFO: 17991 processes: 10330 remote cache hit, 5888 internal, 1773 local.
```

Wall time **~2 min 47 s**. All 10,330 compilation outputs came straight from BuildBarn's Action Cache — **zero remote executions**. The remaining 1,773 local actions are linking/archiving that we deliberately keep on the client. Speedup vs cold cache: **≈11×**, vs local 3-hour build: **≈65×**.

**Unchanged code rebuild** (local disk cache still warm, no `bazel clean`):

```
INFO: Elapsed time: 1.607s, Critical Path: 0.38s
INFO: 1 process: 1 internal.
```

Near-instant — Bazel only checks timestamps, nothing to do.

#### Profile analysis (install-dist-test, cold cache, tuned)

Time distribution from `--profile=/tmp/profile.json.gz`:

| Category | Total time | Share |
|----------|-----------|-------|
| general information | 162,952s | 26.5% |
| action processing | 153,828s | 25.0% |
| remote action execution | 147,981s | 24.0% |
| Remote execution process wall time (actual CPU) | 56,801s | 9.2% |
| Remote execution file fetching | 45,388s | **7.4%** |
| Remote execution queuing time | 34,630s | 5.6% |
| Remote execution upload time | 7,185s | 1.2% |

Per-action averages:

| Action | Count | Avg time |
|--------|-------|----------|
| `Compiling` | 9,415 | **16.0s** |
| `fetch` (input fetch) | 9,899 | **4.6s** |
| `queue` (wait for worker) | 8,675 | 4.0s |
| `upload` (outputs) | 19,466 | 0.49s |
| `download` (results to client) | 325 | 0.43s |

Before cache tuning the `fetch` average was ~84s per action because every action re-downloaded the MongoDB toolchain (several GB) from central CAS. After increasing worker cache to 100GB / 1M files, toolchain files stay hardlinked between actions, and `fetch` dropped to 4.6s (≈18× faster).

#### PoC runner image validation (`psmdb-runner-ubuntu-noble-x86_64:poc`)

After switching from the hand-curated `psmdb-runner:latest` image to a new image built by running `psmdb_builder.sh install_deps()` verbatim inside a Dockerfile (see `IaC/buildbarn/runners/`), the cluster was revalidated in three phases. The runner image is ~1.73 GB on disk / 441 MB content (vs 794 MB / 198 MB baseline) because it includes the full Jenkins build-env package list (Go SDK, valgrind, devscripts, etc.) rather than a trimmed subset.

| Run | Nodes on PoC image | Mode | Wall time | Remote cache hit | Remote exec | Local | Internal | Exit |
|-----|--------------------|------|-----------|------------------|-------------|-------|----------|------|
| Baseline (pre-PoC) | 0/3 | warm | **2 min 47 s** | 10,330 | 0 | 1,773 | 5,888 | 0 |
| 1 × worker on PoC | 1/3 (`barn-psmdb-worker-2`) | warm | **3 min 01 s** | 10,330 | 0 | 1,773 | 5,888 | 0 |
| 1 × worker on PoC | 1/3 (`barn-psmdb-worker-2`) | `--noremote_accept_cached` | **22 min 59 s** | 0 | **10,330** | 1,773 | 5,888 | 0 |
| Full rollout | **3/3 + mongot** | warm | **3 min 07 s** | 10,330 | 0 | 1,773 | 5,888 | 0 |

Critical observations:

- **Zero action failures across 10,330 remote executions during the `--noremote_accept_cached` run.** In a heterogeneous cluster (1 of 3 workers on the new image), scheduler distribution of ~1:1:1 means ~3,400 actions executed on the PoC image successfully. This is strong evidence the PoC image is functionally equivalent to the baseline for PSMDB Bazel builds.
- **Hermetic toolchain verified**: the compile processes on PoC workers run `external/mongo_toolchain_v5/stow/gcc-v5/libexec/gcc/x86_64-mongodb-linux/14.2.0/cc1plus` — i.e. Bazel pulls the MongoDB toolchain from `mongo_toolchain_v5` at execution time regardless of what is installed on the host. Host-level `mongodbtoolchain v4` and `aws_sdk_build` in `install_deps()` can therefore be safely disabled in the runner image (tracked as size-reduction follow-up).
- **Warm rebuild is insensitive to worker count at ~100% cache hit rate.** After full rollout (3 nodes + mongot = 4 nodes), the warm time was 3:07 vs the single-PoC-node 3:01 — the extra worker slots sit idle because no actions execute. Warm wall time is dominated by client-side action-graph processing, gRPC RTT to frontend, and local linking, not remote compute.
- `--noremote_accept_cached` disables Action Cache lookup but **keeps CAS (blob) reads**, so it is not a true cold build — toolchain tarballs and source blobs are still served from cache. Hence 22:59 is a "semi-cold" measurement and is not directly comparable to the 30-min original cold baseline (which ran against a cold CAS).

#### Second variant: `psmdb-runner-debian-bookworm-x86_64:poc`

Proves the Dockerfile pattern clones across distros with a single-line change (`FROM debian:bookworm` instead of `FROM ubuntu:24.04`), and that the multi-pool BuildBarn setup routes a Debian client to a Debian runner. Run on `barn-psmdb-worker-2` with two runner services sharing the node (12 + 12 slots, then retested with 24 + 24 after splitting pools proved functional).

| Run | Pool | Mode | Wall time | Processes (cache hit / remote / local / internal) | Exit |
|-----|------|------|-----------|----------------------------------------------------|------|
| First cold Debian | bookworm 24-slot (worker-2 only) | cold AC, warm CAS | **1 h 43 min 42 s** | 0 / 10,330 / 1,773 / 5,888 | 0 |

Process counts match ubuntu-noble's `--noremote_accept_cached` run exactly (`10330 / 1773 / 5888`), confirming the action graph and strategy allocation are identical regardless of runner distro.

**Three cross-cutting findings from this run:**

1. **OpenSSL linkage is non-hermetic.** `mongod --version` reports different `openSSLVersion` depending on which runner built it:

   | Runner image | Reported `openSSLVersion` |
   |--------------|----------------------------|
   | ubuntu-noble-x86_64 | `OpenSSL 3.0.13 30 Jan 2024` (from Ubuntu 24.04 `libssl3t64`) |
   | debian-bookworm-x86_64 | `OpenSSL 3.0.19 27 Jan 2026` (from Debian 12 `libssl3`) |

   All other fields (`gitVersion`, `perconaFeatures`, `allocator`, `target_arch`) are identical. This is evidence that `mongo_toolchain_v5` is hermetic only for the C/C++ toolchain (gcc, cc1plus, ld); third-party shared libraries (OpenSSL, krb5, ldap, etc.) resolve against the runner's `/usr/lib`. **This is the argument for real per-distro runners rather than a single "universal" image with multiple platform advertisements** — a Debian `.deb` must ship linked against Debian libs, or package dependencies/ABI will not match on the customer's host. Option Y (separate images per distro) therefore remains the correct architecture going into §11.5.

2. **OOM at `concurrency=24` on PSMDB template-heavy files.** Mid-build, kernel OOM-killed one `cc1plus` while compiling `src/mongo/db/s/resharding/*_coordinator_part_*.cpp` on the 30.6 GB worker-2. Peak memory for the heaviest PSMDB compile actions is **~2–3 GB per cc1plus** (sharding/resharding coordinators, extension IDL-generated files, collection sharding runtime). With 24 parallel compilations that is ~60 GB working set on a 32 GB node → overcommit.

   ```
   dmesg:
   oom-kill: task=cc1plus, total-vm:1970232kB, anon-rss:1822988kB
   Out of memory: Killed process 254320 (cc1plus)
   ```

   **Remediation adopted: add 32 GB swap on each worker.** Not dropping concurrency, because:
   - Dropping 24 → 14 would cost throughput equivalent to losing 1–2 permanent Hetzner nodes
   - Swap thrashing adds wall-time cost only for the few memory-heavy files (the tail of the build) — the rest fit in RAM
   - Swap is already the natural mitigation for PSMDB developers building locally on 16–32 GB laptops; matches field practice
   - A proper CPU/memory upgrade (Hetzner `ccx43` = 16 cores + 64 GB dedicated) is blocked by the current tariff limit of 8 dedicated CPUs. Shared tier caps at 32 GB RAM regardless of core count.

   `sudo fallocate -l 32G /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile` on each worker, plus an `/etc/fstab` entry to persist.

3. **Multi-pool on one worker works as designed.** `worker-2` advertises two platform pools (ubuntu24 + debian12) on the same `bb_worker` process via two `runners[]` entries pointing at two runner Unix sockets (`/worker/runner-noble`, `/worker/runner-bookworm`). Two separate runner containers (`runner-noble`, `runner-bookworm`) run distinct images and execute actions for their respective pools. `docker stats` mid-build showed `runner-bookworm` at ~1300% CPU (real cc1plus compilation), `runner-noble` at 0% (no noble work queued), confirming the scheduler routes each client's distro-autodetected platform to the correct pool. Worker-2 went from one pool × 24 slots to two pools × 12 + 12 in initial test, then to 24 + 24 with swap for production behavior. **Concurrency across pools on the same worker is not dynamically shared** (see §9.8); each pool has its own hard cap. For single-distro builds this means idle slots in the other pool are wasted; acceptable while Hetzner capacity is not the binding constraint.

### 9.8 Performance Bottlenecks

| Bottleneck | Symptom | Solution |
|------------|---------|----------|
| Small worker cache (toolchain re-download) | Actions show `200s+ remote` but actual compile is <10s. Profile shows `fetch` avg ≈ `Compiling` avg | Increase `maximumCacheSizeBytes` to 100 GB and `maximumCacheFileCount` to 1,000,000 in every worker config |
| Small central CAS | Workers re-fetch the same blobs repeatedly, CAS evictions under load | Increase CAS block and key-map sizes in `storage.jsonnet` (see Part 5.7) |
| Critical path | `Critical Path` is high relative to `Elapsed time` | Nothing — sequential dependencies can't be parallelized. Reducing it requires refactoring BUILD files |
| Network bandwidth | Slow input upload / output download | Place client and workers in same datacenter (private network) |
| Cold worker cache | `context canceled` or `Failed to obtain input file` on new workers | Transient — clears after first build warms the cache. Reduce concurrency on fresh nodes initially |
| Local linking | Final link step takes minutes on client | Linking stays local by design (`--strategy=CppLink=local`). Use a powerful client machine |
| `java.lang.OutOfMemoryError` writing execution log | Crash **after** build finishes when using `--execution_log_json_file` on large builds | Use `--execution_log_compact_file=...` (binary proto) or drop the flag. JSON log blows up Bazel heap for 18k-action builds |
| OOM-kill of `cc1plus` on memory-heavy PSMDB compile actions | `dmesg` shows `oom-kill` on `cc1plus` (typically in `resharding/coordinator_*.cpp` or collection sharding runtime). Build enters recovery / appears hung for minutes | PSMDB's heaviest compile units peak at ~2–3 GB RSS each. `concurrency × 2.5 GB` must fit in RAM + swap. **Add 32 GB swap on each worker** rather than dropping concurrency (see §9.7 second-variant finding #2). Alternative: upgrade to 64 GB RAM instances if tariff allows |

To profile in detail, add `--profile=/tmp/build-profile.json.gz` to the build command. Analyse directly on the server without downloading:

```bash
zcat /tmp/build-profile.json.gz | python3 -c "
import json, sys
from collections import defaultdict
data = json.load(sys.stdin)
events = data.get('traceEvents', data) if isinstance(data, dict) else data
by_cat = defaultdict(int)
for e in events:
    by_cat[e.get('cat', 'unknown')] += e.get('dur', 0)
total = sum(by_cat.values())
print(f'Total: {total/1e6:.0f}s ({total/1e6/60:.1f}min)')
for cat, dur in sorted(by_cat.items(), key=lambda x: -x[1]):
    print(f'{dur/1e6:>10.1f}s ({100*dur/total:>5.1f}%)  {cat}')
"
```

Per-action averages:

```bash
zcat /tmp/build-profile.json.gz | python3 -c "
import json, sys
from collections import defaultdict
data = json.load(sys.stdin)
events = data.get('traceEvents', data) if isinstance(data, dict) else data
stats = defaultdict(lambda: [0, 0])
for e in events:
    if 'dur' not in e: continue
    name = e.get('name', '').split(' ')[0]
    stats[name][0] += e['dur']; stats[name][1] += 1
print(f'{\"Name\":<40} {\"Count\":>8} {\"Total(s)\":>10} {\"Avg(s)\":>10}')
for name, (dur, cnt) in sorted(stats.items(), key=lambda x: -x[1][0])[:20]:
    print(f'{name[:40]:<40} {cnt:>8} {dur/1e6:>10.1f} {dur/cnt/1e6:>10.2f}')
"
```

Or open the `.json.gz` file in `chrome://tracing` / `ui.perfetto.dev`.

### 9.9 Fallback Behavior When BuildBarn Is Unavailable

Our current `.bazelrc.local` sets `--spawn_strategy=remote,local` and `--strategy=CppCompile=remote,local`. This controls *which strategy Bazel picks first*, but it **does NOT automatically fall back to local execution when the remote cluster is unreachable**. Behavior by scenario:

| Scenario | Default behavior | With `--remote_local_fallback=true` |
|----------|------------------|--------------------------------------|
| BuildBarn unreachable at build start (capabilities RPC fails) | **Build fails immediately** with gRPC error | Build runs fully locally (≈3 h for `install-dist-test`) |
| BuildBarn crashes mid-build | Actions retry `--remote_retries` times (default 5), then **fail** | Per-action fallback to local execution, build continues |
| Only `--remote_cache` unreachable (executor up) | Build continues without cache (graceful) | Same |
| `.bazelrc.local` removed / remote flags cleared | Pure local build (explicit, no fallback involved) | Same |

**Recommendation:**

- **Developer machines** where BuildBarn is a convenience, not a requirement — add to `.bazelrc.local`:

  ```
  common:local --remote_local_fallback=true
  common:local --remote_retries=2
  ```

  Accepts ~3 h fallback time if BuildBarn is down rather than failing the build.

- **CI / release builds** where a silent switch to slow local execution would hide infrastructure failures — leave default (or set `--remote_local_fallback=false` explicitly). Fail loud, fix BuildBarn, retry.

`--remote_local_fallback` is marked deprecated in upstream Bazel 8+ but still works in MongoDB's REAPI v2.0 fork used for PSMDB.

## Part 10: Current Status

### What Works

- **PSMDB `install-mongod` and `install-dist-test` build successfully** via remote execution on the `master` branch
- `install-dist-test` cold build (17,991 actions): **~30 min** vs ~3 hours locally — ≈6× speedup
- `install-dist-test` warm remote cache (after `bazel clean`): **~2 min 47 s** (pre-PoC baseline) / **~3 min 07 s** (post-PoC rollout), 10,330/10,330 compile actions served from Action Cache — ≈65× faster than local
- `install-mongod` cold build (3,217 actions): **~67 min** on the same setup before cache tuning
- Unchanged-code rebuild (local cache warm): **1.6 s**
- BuildBarn central server + 2 dedicated worker nodes (permanent) + 1 ephemeral node deployed and operational
- REAPI v2.0 proxy patches capabilities — MongoDB's Bazel fork (REAPI v2.0) works with BuildBarn (REAPI v2.3+)
- Worker local cache tuned to 100 GB / 1M files — toolchain stays hardlinked between actions, fetch dropped from 84 s to 4.6 s average
- Central CAS/AC sizes increased to keep MongoDB toolchain blobs resident
- **Runner image `psmdb-runner-ubuntu-noble-x86_64:poc`** on every hardlinking-pool node — built from `psmdb_builder.sh install_deps()` (see `IaC/buildbarn/runners/`) rather than a hand-curated package list. Validated via 10,330 remote executions with zero failures; see §9.7 PoC runner image validation.
- **Second variant `psmdb-runner-debian-bookworm-x86_64:poc`** validated on `barn-psmdb-worker-2` through full `install-dist-test` cold build (10,330 remote executions, exit 0). Proves the single-line-`FROM` Dockerfile pattern clones across distros and that multi-pool BuildBarn routes correctly. See §9.7 second-variant subsection.
- **Multi-pool worker architecture** on `worker-2` — one `bb_worker` process advertises two platform pools (ubuntu24 + debian12) by spawning two runner containers with distinct Unix sockets. Scheduler routes clients to the matching pool based on the `container-image` property the client auto-detects from its host OS. Blueprint for §11.5 per-variant worker configuration.
- **Dev-environment symmetry confirmed** — the same `psmdb-runner-*-x86_64:poc` image is usable both as a BuildBarn worker runtime **and** as an interactive developer shell (`docker run -it -v $SRC:/src image bash` → `install_bazel.py && bazel build ...` works end-to-end). `install_bazel.py` is Python stdlib-only and runs fine on Debian 12's stock Python 3.11; the deadsnakes Python-3.13 block in `psmdb_builder.sh` is non-fatal on Debian and not required for the Bazel build path.
- Python wheel downloads work (runner has network access)
- Platform property matching configured (exact match, lexicographic sorting)

### What Could Be Improved

1. **Local linking** — final link step runs on the client and can dominate wall time after remote actions complete. A more powerful client or distributed linking would help.
2. **Hardlinking vs FUSE** — currently using hardlinking workers due to shared-VPS kernel restrictions. Dedicated bare-metal with FUSE workers would enable lazy input loading and reduce fetch time further.
3. **Runner image size** — current PoC image is ~1.73 GB on disk (Ubuntu Noble) / ~2.17 GB (Debian Bookworm) because `psmdb_builder.sh install_deps()` pulls in Go SDK, valgrind, devscripts/debhelper, and other packages that are only needed for Jenkins non-Bazel phases. Bazel execution itself uses its own hermetic toolchain (`mongo_toolchain_v5`) at runtime. Commenting `install_mongodbtoolchain`, `aws_sdk_build`, and `install_golang` in the local `psmdb_builder.sh` copy should shrink the image by ≈800 MB; tracked as a size-reduction follow-up.
4. **Runner image distribution** — currently bit-identical on all nodes via `docker save | scp | docker load`. For scaling to 17 variants × N nodes this needs to move to a registry (ghcr.io / Percona / Quay — decision pending, see §11.4).
5. **Execution log** — `--execution_log_json_file` crashes the client on large builds (OOM). Use `--execution_log_compact_file` or drop the flag.
6. **Worker RAM pressure at `concurrency=24`** — PSMDB's heaviest compile units (sharding/resharding coordinators, collection sharding runtime, IDL-generated extension files) peak at ~2–3 GB RSS per `cc1plus`. On a 32 GB Hetzner `cpx51` that exceeds physical RAM when 20+ of them schedule concurrently, triggering OOM-kill (observed during the debian-bookworm cold run, §9.7). **Decision: add 32 GB swap on each worker rather than drop concurrency** — lowering slots 24 → 14 costs throughput equivalent to losing 1–2 permanent nodes, and swap only affects the tail of the build where memory-heavy files compile. A proper upgrade to 64 GB RAM workers (Hetzner `ccx43`) is blocked by the current 8-dedicated-CPU tariff cap; the shared tier tops out at 32 GB RAM regardless of core count. Same swap-based mitigation is recommended for developers building PSMDB locally on 16–32 GB machines — it is already the de-facto practice in the field.
7. **No dynamic concurrency sharing between pools on one worker** — if `worker-2` advertises 24 slots noble + 24 slots debian12 and only one distro has work, the other pool's slots sit idle (no cross-pool stealing). For true elastic sharing, `cpu_shares` / `cpus` caps on the Docker containers combined with high per-pool `concurrency` would let Linux CFS rebalance; revisit once multi-distro concurrent load is real.

### Infrastructure

Permanent nodes (always present):

Live IPs for these nodes are recorded in `INFRASTRUCTURE.md` (the
operator runbook — see `INFRASTRUCTURE.md.example` for the template),
not here, so the public mirror of this repo doesn't double as a
target list for opportunistic scanners. Cross-reference by hostname
when reading this section against a live cluster.

| Server | Public IP | Private IP | Role | `nproc` | Concurrency | Runner image |
|--------|-----------|------------|------|---------|-------------|--------------|
| barn-psmdb | (see runbook) | (see runbook) | Central (frontend, scheduler, storage, worker, proxy) | 16 | 12 (≈×0.75, undersubscribed — shares with storage/scheduler/frontend) | `psmdb-runner-ubuntu-noble-x86_64:poc` on the `hardlinking` pool; fuse pool retains `ghcr.io/catthehacker/ubuntu:act-22.04` (unused by PSMDB) |
| barn-psmdb-worker-1 | (see runbook) | (see runbook) | Worker node (worker + runner) | 16 | 24 (×1.5 oversubscribed) | `psmdb-runner-ubuntu-noble-x86_64:poc` |
| barn-psmdb-worker-2 | (see runbook) | (see runbook) | Worker node (worker + runner, **multi-pool**) | 16 | 24 on ubuntu24 pool **+** 24 on debian12 pool (independent caps; see §9.7 second variant) | `psmdb-runner-ubuntu-noble-x86_64:poc` (ubuntu24 pool) **+** `psmdb-runner-debian-bookworm-x86_64:poc` (debian12 pool) |

All workers have **32 GB swap** enabled to absorb peak memory on PSMDB's ~2–3 GB RSS `cc1plus` compilations (see §10 Improvements #6).

Ephemeral / experimental nodes (may come and go):

| Server | Role | `nproc` | RAM | Concurrency | Runner image | Notes |
|--------|------|---------|-----|-------------|--------------|-------|
| psmdb-mongot | Worker node (worker + runner) | 12 | 22 GB | 18 (×1.5 oversubscribed) | `psmdb-runner-ubuntu-noble-x86_64:poc` | Temporary extra capacity (see §11.4 registry/rollout notes). Safe to remove at any time. |

Hardlinking-pool worker concurrency (where PSMDB builds actually run):

| Pool (by `container-image` SHA) | Pool name | Slots | Notes |
|----------------------------------|-----------|-------|-------|
| `...@sha256:f1bd96...` | ubuntu24 | `12 + 24 + 24 (+ 18 mongot) = 78` | All 4 hardlinking nodes advertise this |
| `...@sha256:d1df0f...` | debian12 | `24` | worker-2 only (second pool on same physical host) |

Client invokes with `--jobs=96` so the scheduler always has work queued regardless of whether the ephemeral node is live. The bb-browser "N idle workers" counter reflects live pool size (78 ubuntu24 + 24 debian12 = 102 total slots when mongot is present).

**Central is intentionally undersubscribed** (concurrency 12 on 16 cores, ×0.75). The node also hosts `frontend`, both `storage` shards, `scheduler`, `browser`, `runner-installer`, and the REAPI proxy. Raising concurrency here has asymmetric risk: a worker-node overload slows only that one node, but central overload degrades the shared CAS and scheduler, which slows the entire cluster. Any future attempt to raise 12 → 18 should be measured with `--noremote_accept_cached` before and after to confirm the change is not a net regression.

**Why ×1.5 oversubscription on dedicated workers works for PSMDB.** Remote compilation actions spend a meaningful share of their wall time on I/O (fetching toolchain/header inputs, uploading object files) rather than pure CPU. With `concurrency = nproc`, those I/O-waiting slots leave cores idle. Raising concurrency to `nproc × 1.5` keeps cores busy while one slot is blocked on fetch/upload. For pure-CPU workloads (or when the worker cache is cold and every slot is bottlenecked on `fetch`), oversubscription can hurt — benchmark before settling on a value.

### Ports

| Port | Service | Host |
|------|---------|------|
| 8980 | BuildBarn frontend (gRPC, direct) | barn-psmdb (see runbook for IP) |
| 8981 | Envoy proxy (gRPC, for PSMDB clients) | barn-psmdb (see runbook for IP) |
| 7984 | bb-browser (HTTP) | barn-psmdb (see runbook for IP) |
| 7982 | Scheduler admin (HTTP) | barn-psmdb (see runbook for IP) |

## Part 11: Release Matrix Roadmap

> **Status: planning.** The deployment described in Parts 1–10 proved out single-platform PSMDB builds (`Ubuntu Noble x86_64`, glibc 2.39) via BuildBarn with 6× speedup cold and 65× warm. The next step is extending it to the full release matrix — this section captures the plan, confirmed decisions, and open work so the context is not lost between sessions.

### 11.1 Target release matrix

PSMDB release is currently built in parallel on Jenkins + Hetzner local workers, ~2–3 hours per variant:

| Platform | x86_64 | aarch64 |
|----------|--------|---------|
| Oracle Linux 8 (glibc 2.28) | ✓ | ✓ |
| Oracle Linux 9 (glibc 2.34) | ✓ | ✓ |
| Amazon Linux 2023 (glibc 2.34) | ✓ | ✓ |
| Ubuntu Jammy 22.04 (glibc 2.35) | ✓ | ✓ |
| Ubuntu Noble 24.04 (glibc 2.39) | ✓ | ✓ |
| Debian Bookworm 12 (glibc 2.36) | ✓ | — |
| Oracle Linux 8 binary tarball (glibc 2.28) | ✓ | — |
| Oracle Linux 9 binary tarball (glibc 2.34) | ✓ | — |
| Amazon Linux 2023 binary tarball (glibc 2.34) | ✓ | — |
| Ubuntu Jammy 22.04 binary tarball (glibc 2.35) | ✓ | — |
| Ubuntu Noble 24.04 binary tarball (glibc 2.39) | ✓ | — |
| Debian Bookworm 12 binary tarball (glibc 2.36) | ✓ | — |

Total: **17 variants** across 5 distinct glibc versions (2.28, 2.34, 2.35, 2.36, 2.39) and 2 architectures (x86_64, aarch64). Plus 3–5 concurrent developer/master builds on the same cluster.

### 11.2 Capacity baseline (from measurements)

One `install-dist-test` cold build on current cluster (Part 9.7):

| Metric | Value |
|--------|-------|
| Remote execution CPU time | 56,801 s ≈ 15.8 core-hours |
| Compile actions | 9,415 |
| Avg compile | 16.0 s |
| Wall time on 60 slots | 30 min |

Extrapolation to full cold release matrix (assuming **no cross-variant cache sharing** — each variant has different `container-image` exec property, producing different action cache keys):

```
17 variants × 56,801 s = ~966,000 CPU-s = ~268 core-hours
```

| Cluster size (physical cores) | Theoretical min wall time for full cold matrix |
|-------------------------------|------------------------------------------------|
| 48 (current) | ~5.6 h (100% utilization, unrealistic) → realistic **~7–9 h** |
| 96 | ~2.8 h realistic |
| 144 | ~1.9 h realistic |

Warm rebuild (action cache populated from previous run, no code changes): **~50 min paralel** — dominated by local linking on Jenkins agents, not by remote execution.

### 11.3 Confirmed feasibility decisions

| Question | Decision | Implication |
|----------|----------|-------------|
| **2.1 aarch64 support** | Hetzner ARM instances (CAX series) are available and cheap. Going native — no cross-compile. | Need separate aarch64 worker pool with aarch64-native runner images |
| **2.2 glibc variants** | Build custom runner images per `(OS, glibc)` combination based on `percona-packaging/scripts/psmdb_builder.sh install_deps()` function. | Owned, maintained as a spinoff project. Rebuild cadence TBD (daily or weekly) to keep base images fresh and catch upstream package drift |

`install_deps()` in `psmdb_builder.sh` already encodes per-OS package lists (RHEL 7/8/9/2023 branches + Debian/Ubuntu branch with `DEBIAN` variants). These lists are the exact source of truth for runner image `Dockerfile`s — one runner per row of the matrix in 11.1.

### 11.4 Runner image production plan

**Current implementation:** `IaC/buildbarn/runners/` (this repo). Structure in place, populated for the PoC variant:

```
IaC/buildbarn/runners/
├── README.md                          # strategy, directory layout, build/deploy workflow
├── psmdb_builder.sh                   # local copy of upstream psmdb_builder.sh, shared by all variants
├── ubuntu-noble-x86_64/               # validated, in production on all hardlinking-pool nodes (§9.7)
│   └── Dockerfile
├── debian-bookworm-x86_64/            # validated on worker-2 via multi-pool setup (§9.7 second variant)
│   └── Dockerfile
├── ubuntu-jammy-x86_64/               # pending
├── ubuntu-jammy-aarch64/              # pending
├── ubuntu-noble-aarch64/              # pending
├── oracle-linux-8-x86_64/             # pending
├── oracle-linux-8-aarch64/            # pending
├── oracle-linux-9-x86_64/             # pending
├── oracle-linux-9-aarch64/            # pending
├── amazon-linux-2023-x86_64/          # pending
├── amazon-linux-2023-aarch64/         # pending
└── .github/workflows/
    └── weekly-rebuild.yml             # pending — rebuild all variants weekly, push to registry
```

**Strategy.** Each Dockerfile fetches `IaC/buildbarn/runners/psmdb_builder.sh` from this repo over HTTP (via `wget`) and runs it with `--install_deps=1`. No package list is duplicated into the Dockerfiles — the script is the single source of truth. Bazel's internal guards in every `build_*` phase ensure only `install_deps()` runs when the other flags default to `0`. Upstream changes to `percona-server-mongodb/percona-packaging/scripts/psmdb_builder.sh` are pulled into the local copy by a conscious `cp` + review step.

**Each variant × arch produces one image:**

```
<registry>/psmdb-runner-ubuntu-noble-x86_64:YYYYMMDD
<registry>/psmdb-runner-ubuntu-noble-aarch64:YYYYMMDD
<registry>/psmdb-runner-ol8-x86_64:YYYYMMDD
<registry>/psmdb-runner-ol8-aarch64:YYYYMMDD
<registry>/psmdb-runner-ol9-x86_64:YYYYMMDD
...
<registry>/psmdb-runner-debian-bookworm-x86_64:YYYYMMDD
```

**Build frequency:** weekly rebuild covers security patches; daily is overkill unless upstream package repos are unstable. Pin to a date tag in `worker.jsonnet` to avoid silent drift mid-release.

**PoC validation status:**
- `ubuntu-noble-x86_64` — validated against `install-dist-test` with 10,330 remote executions, zero failures, in both heterogeneous (1 of 3 workers) and full-rollout (4 of 4 workers) configurations. Wall-clock within noise of the pre-PoC baseline. See §9.7 PoC runner image validation.
- `debian-bookworm-x86_64` — validated via multi-pool deployment on worker-2: a separate `debian12` pool with its own `runner-bookworm` container handles Debian-client builds while the existing ubuntu24 pool continues serving noble traffic unchanged. Full `install-dist-test` cold build completed with 10,330 remote executions, zero failures (1 h 43 min 42 s wall time, with OOM+swap recovery mid-build). See §9.7 second variant subsection. Also surfaced the non-hermetic OpenSSL observation that justifies real per-distro runners rather than a single universal image.

**Open decision:** private registry location. Options: Percona internal registry, `ghcr.io`, `quay.io`, `hub.docker.com/u/perconalab`. Needs alignment with security/access policy. Until chosen, the PoC image is replicated on each worker node via `docker save` / `scp` / `docker load` from `barn-psmdb-worker-2` (where it is first built). This is fine for 1 variant × 4 nodes but does not scale to 17 variants × N nodes — the registry decision is a hard prerequisite for step 3 of §11.7.

### 11.5 BuildBarn configuration changes

Once runner images exist, BuildBarn side needs:

**a) Per-variant worker pools via `platform.properties`**

Each worker declares which variant it serves:

```jsonnet
platform: {
  properties: [
    { name: 'Arch', value: 'x86_64' },              // or 'aarch64'
    { name: 'OSFamily', value: 'oracle-linux-8' },  // PSMDB-specific namespace
    { name: 'Pool', value: 'x86_64' },              // kept for backward compat
    { name: 'container-image', value: 'docker://<registry>/psmdb-runner-ol8-x86_64:20260415' },
    { name: 'dockerNetwork', value: 'standard' },
  ],
},
```

Client release jobs request the matching variant via `--remote_default_exec_properties=OSFamily=oracle-linux-8 --remote_default_exec_properties=Arch=x86_64`. PSMDB's `.bzl` rules probably need updating to pass the right `exec_properties` per configured target platform — **this is a Bazel-side change that needs PSMDB buildscript work, not just BuildBarn**.

**b) Storage scaling**

17 variants × unique CAS footprint (~15 GB each for toolchain + objects + binaries):

| Resource | Current | Release-matrix target |
|----------|---------|------------------------|
| CAS `blocks.sizeBytes` per shard | 200 GB | **500 GB** (or add 3rd shard) |
| CAS `key_location_map.sizeBytes` | 4 GB | **8 GB** |
| AC `key_location_map.sizeBytes` | 50 MB | **300–500 MB** (17× more unique entries) |
| Central server disk | 640 GB | **needs audit** — 2 shards × 500 GB = 1 TB just for CAS |
| Worker `maximumCacheSizeBytes` | 100 GB | **200–300 GB** (cold worker pulls multiple toolchains) |

**c) Scheduler prioritisation**

Default BuildBarn scheduler is FIFO per platform pool. A release job can be blocked behind a dev build on the same pool. Options:

1. **Priority hints** (preferred — minimal config change): Jenkins release jobs pass `--remote_execution_priority=-100` (lower number = higher priority), dev/master builds stay at default 0. Requires Bazel 7.0+ client and scheduler support verification.
2. **Separate pools** (strongest isolation, lowest utilization): tag release workers `Tier=release`, dev workers `Tier=dev`. Client selects via exec_properties.
3. **Dedicated BuildBarn instance** (heaviest — doubles infrastructure).

Start with (1), measure dev-build starvation under real release load, escalate if needed.

**d) Capacity target**

Assuming "release matrix must complete in ≤ current 2–3 h wall time even under concurrent dev load":

```
Release matrix alone: ~268 core-hours cold, ~15 core-hours warm (action cache hits)
+ 3–5 dev builds: ~50–80 core-hours
Total: ~320 core-hours worst case
```

For 2.5 h wall time: `320 / 2.5 = ~128 physical cores`. Current cluster: 48 cores. **Need ~+80 cores** on dedicated workers, split between x86_64 and aarch64 roughly by matrix row count (11 x86_64 + 5 aarch64 tarball-less rows):

- **+3 x86_64 workers** (e.g. Hetzner CPX51 or dedicated) ≈ 48 cores
- **+2 aarch64 workers** (Hetzner CAX41/CAX51) ≈ 32 cores

Exact sizing should be re-validated after runner images exist and one full release run gives real numbers.

### 11.6 Jenkins integration

Jenkins agents become BuildBarn clients:

1. Agent pulls PSMDB source (as today)
2. Agent has `.bazelrc.local` with `--remote_executor=grpc://barn-psmdb:8981` and variant-specific exec_properties
3. `bazel build` runs remotely on BuildBarn, linking stays on the agent (by current `--strategy=CppLink=local`)
4. Final `.deb`/`.rpm`/tarball is produced on the agent and published to Percona repo

**Bandwidth audit:** each variant ships ~few-hundred-MB of outputs back to the agent. 17 parallel agents × 500 MB = ~8.5 GB. On Hetzner private network (10 Gb/s) this is seconds; on public WAN it could be minutes. **Keep agents and BuildBarn in the same datacenter region.**

**Open Jenkins-side work:**
- Migrate one variant first (e.g. `Ubuntu Noble x86_64 tarball`) end-to-end, measure wall time vs current local build
- Verify that `install-package`/`install-dist-test` bazel targets produce Jenkins-expected artefact layout
- Handle secrets (any creds used during `pip install`, `yum install` — already solved for current dev runner, may differ per OS)

### 11.7 Sequenced next steps

In order of dependency — each step unblocks the next:

1. **Pick registry** for runner images (Percona internal / `ghcr.io` / `quay.io` / `hub.docker.com/u/perconalab`). Needed before any automation. **Still open.**
2. ~~**Build 1 runner image** for `ubuntu-noble-x86_64` using `install_deps()`. Validate it runs an `install-dist-test` build through BuildBarn with the same or better numbers than current `psmdb-runner:latest` (this is the control).~~ **Done.** `IaC/buildbarn/runners/ubuntu-noble-x86_64/` implemented, validated with 10,330 remote executions (§9.7), rolled out to all hardlinking-pool nodes.
3. **Extend to all remaining variants** — Dockerfiles in `IaC/buildbarn/runners/<variant>/`, each differing only by `FROM <distro>:<version>`. The shared `psmdb_builder.sh` auto-detects the OS via `get_system()`. Add CI job (pending registry decision at step 1) for weekly rebuild. **In progress**: `ubuntu-noble-x86_64` and `debian-bookworm-x86_64` done and validated end-to-end (§9.7); 9 x86_64 variants + 5 aarch64 variants pending.
4. **Add aarch64 infrastructure**: 1 Hetzner CAX41 as PoC, BuildBarn worker config with `Arch=aarch64` property. Run one aarch64 variant end-to-end.
5. **Update PSMDB Bazel rules** to emit correct `exec_properties` per target platform (`--config=release-ol8-x86_64` etc.). This is the biggest unknown — may need MongoDB Bazel fork investigation.
6. **Run one full release matrix** on BuildBarn, measure actual wall time + CAS/AC footprint. Adjust sizing (11.5) based on real numbers.
7. **Integrate with Jenkins** — one variant first, then rest.
8. **Add scheduler priority** to protect release runs from dev build interference.
9. **Scale capacity** (+3 x86_64, +2 aarch64) based on measured vs target wall time.

### 11.8 Open risks & unknowns

- **Cross-variant action cache sharing unknown.** If `exec_properties` differ only in `container-image`, action keys are fully distinct — zero sharing. If PSMDB toolchain/source analysis phase is cacheable across variants (e.g. generated `.h` files not depending on target OS), there's partial sharing. Needs measurement on variants 2+ to confirm.
- **MongoDB Bazel fork tolerance for new `exec_properties`** — PSMDB's `.bzl` files currently hardcode `Pool=x86_64` and the MongoDB remote-execution image. Adding per-variant `OSFamily`/`Arch`/`container-image` properties may need upstream (fork) patch.
- **REAPI v2.0 proxy + multi-pool**: Envoy currently routes everything to one frontend. Multi-pool BuildBarn might want multiple frontends or per-instance-name routing; verify proxy stays simple.
- **Storage growth unbounded** — 17 variants × weekly churn × multiple branches could overflow even 500 GB CAS. Plan retention policy (BuildBarn CAS is LRU-evicted, but monitor eviction rate).
- **Network cost on public IPs** — moving release bandwidth off Hetzner's free private net onto public egress could become significant. Put all workers + Jenkins on the same private network.

### 11.9 What NOT to do yet

- Don't add aarch64 workers before an aarch64 runner image exists — nothing to deploy. (The x86_64 PoC image is ready; aarch64 still needs a separate Dockerfile variant + CAX instance.)
- Don't touch PSMDB `.bzl` files before a second variant works — the validated `ubuntu-noble-x86_64` PoC is the baseline to preserve.
- Don't push the PoC image (`psmdb-runner-ubuntu-noble-x86_64:poc`) to any public registry — it's tagged `:poc` to signal disposability. Before any registry push, rename to a dated production tag (`:YYYYMMDD`) and ideally after the size-reduction follow-up in §10 (Improvements #3).
- Don't enable scheduler priorities before there's actual contention to schedule around.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `No workers exist for instance name prefix "fuse"` | FUSE worker is broken. Use `--remote_instance_name=hardlinking` |
| `No workers exist for instance name prefix "hardlinking" platform ...` | Worker platform properties don't match client. Must be **exact match** — same properties, same values, no extras |
| `Platform properties are not lexicographically sorted` | Properties in worker config must be sorted by `name` alphabetically (e.g. `Pool` before `container-image` is wrong — `P` > `c` in ASCII but lowercase matters; actually `container-image` < `dockerNetwork` because `c` < `d`) |
| `GLIBC_2.38 not found` | Runner container image is too old. Replace with MongoDB remote execution image or Ubuntu 24.04+ |
| `The client supported API versions, 2.0 to 2.0, is not supported by the server` | Deploy the REAPI v2.0 proxy (Part 7). Bazel clients must connect to port 8981 (Envoy), not 8980 (direct) |
| `remote_cache_compression requested but remote does not support compression` | Add `--remote_cache_compression=false` to `.bazelrc.local` |
| `Cannot find gcc or CC` | Install gcc: `apt install -y gcc g++` |
| `connection refused` on startup | Wait 5–10 seconds for all containers to initialize |
| Build stuck at `[Sched]` for minutes | Worker is not connected to scheduler. Check `docker compose logs worker-hardlinking-ubuntu22-04` |
| Port 8980 not accessible externally | Check `ss -tlnp \| grep 8980` and firewall rules (`ufw status`) |
| `Temporary failure in name resolution` inside runner | Runner has `network_mode: none`. Comment out this line in `docker-compose.yml` for the hardlinking runner (see Part 8.4) |
| `zlib.h: No such file or directory` (or other `-dev` headers) on remote worker | Runner container is missing dev packages. Build a custom runner image (see Part 8.5) |
| `keepalive time must be positive` | `.bazelrc.psmdb` sets `--grpc_keepalive_time=0s`. Add `common:local --grpc_keepalive_time=30s` to `.bazelrc.local` |
| Build shows `0 remote` processes | Check: (1) `.bazelrc.local` uses `common:local` not bare `common`, (2) worker platform properties match exactly, (3) worker logs have no errors |
| Worker log: `Worker failed readiness check: connection refused` | Runner container is starting. Wait 10–15 seconds — runner needs time to install `bb_runner` binary and start listening on the Unix socket |
| Worker log: `Failed to obtain input file ... context canceled` | Worker is downloading large inputs (toolchain) and client timed out. Transient on cold start — clears after worker cache warms up. Reduce concurrency on new workers initially |
| `FAILED_PRECONDITION: No workers exist for instance name prefix "hardlinking" platform {... "container-image":"...@sha256:<X>"...}` where `<X>` does NOT match what workers advertise | Client's distro auto-detection in `bazel/platforms/remote_execution_containers.bzl` picks a `container-image` SHA no worker pool advertises. Confirm client's distro (e.g. `lsb_release -sc`), find the corresponding entry in `remote_execution_containers.bzl`, then add a matching pool on at least one worker by appending a `runners[]` entry in `worker.jsonnet` with that SHA. Pattern illustrated in §9.7 "Second variant" (ubuntu24 + debian12 on the same `worker-2`) |
| Build hangs for minutes at high `[X / 18,003]` count with processes stuck at thousand-seconds timestamps | Likely OOM-kill recovery (check `dmesg \| grep oom-kill` on workers). If confirmed, add swap on the affected worker (`fallocate -l 32G /swapfile && mkswap /swapfile && swapon /swapfile`) and restart the build. See §10 Improvements #6 |

## References

- BuildBarn deployments repository: https://github.com/buildbarn/bb-deployments
- Bazel remote execution docs: https://bazel.build/remote/rbe
- BuildBarn Slack: `#buildbarn` on [buildteamworld.slack.com](https://bit.ly/2SG1amT)
- MongoDB Bazel remote execution image: `quay.io/mongodb/bazel-remote-execution`
- PSMDB Bazel fork binaries: `s3://mdb-build-public/bazel_binary_waterfall_builds/`
