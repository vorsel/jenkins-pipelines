# BuildBarn Runner Images for PSMDB

Each subdirectory holds a `Dockerfile` for one `(OS, glibc, arch)` combination from the PSMDB release matrix. Images are consumed by BuildBarn runners (`runner-*` service in `docker-compose.yml`) and referenced by the worker `platform.properties.container-image` field.

## Status

The 11-variant matrix is the authoritative list from `../buildbarn-ondemand-scaler.md` §3.1, which in turn mirrors the parallel stages in `psmdb/jenkins/percona-server-for-mongodb-8.3.groovy`. GHA workflow `.github/workflows/build-psmdb-buildbarn-runners.yml` builds all 11 in one run and pushes to `ghcr.io/<owner>/psmdb-buildbarn-runners/<variant>:{<sha>,latest}`.

| Variant | Status | Validation evidence |
|---------|--------|---------------------|
| `ubuntu-noble-x86_64/` | **Production (PoC tag `:poc`)** on all hardlinking-pool nodes of the BuildBarn cluster | 10,330 remote executions with zero action failures on `install-dist-test`, measured with `--noremote_accept_cached` on a heterogeneous cluster (see §9.7 of `../buildbarn-remote-execution-setup.md`) |
| `debian-bookworm-x86_64/` | **Validated** as a second pool (`debian12`) on `barn-psmdb-worker-2`; full cold `install-dist-test` completed | Cold build: 10,330 remote executions, exit 0, 1 h 43 min 42 s wall time (includes OOM+swap recovery mid-build). Identical `gitVersion` and `perconaFeatures` vs noble; different `openSSLVersion` (Debian 3.0.19 vs Ubuntu 3.0.13) proves per-distro runtime libs resolve correctly — see §9.7 "Second variant" in `../buildbarn-remote-execution-setup.md` |
| `ubuntu-jammy-x86_64/`, `ubuntu-jammy-aarch64/`, `ubuntu-noble-aarch64/`, `oraclelinux-8-x86_64/`, `oraclelinux-8-aarch64/`, `oraclelinux-9-x86_64/`, `oraclelinux-9-aarch64/`, `amazonlinux-2023-x86_64/`, `amazonlinux-2023-aarch64/` | **Dockerfile committed; first image build pending GHA run** | `install_deps()` for each of these docker bases (`oraclelinux:8`, `oraclelinux:9`, `amazonlinux:2023`, `ubuntu:jammy`) has been executing on every Jenkins PSMDB 8.3 matrix build for years (see `buildStage(...)` in `psmdb/jenkins/percona-server-for-mongodb-8.3.groovy`). Empirical per-variant validation happens on first GHA run of `.github/workflows/build-psmdb-buildbarn-runners.yml` |

Image sizes: `ubuntu-noble-x86_64:poc` ~1.73 GB on disk / 441 MB content. `debian-bookworm-x86_64:poc` ~2.17 GB / 615 MB. Both are intentionally larger than strictly necessary because `psmdb_builder.sh install_deps()` installs Go SDK, `valgrind`, `devscripts`/`debhelper`, and pip bootstrap — none of which Bazel uses at runtime (Bazel pulls the hermetic `mongo_toolchain_v5` from CAS). Commenting those blocks in the local `psmdb_builder.sh` copy is a pending size-reduction follow-up; until it lands, correctness ≫ size.

**Known non-fatal warning on Debian:** `psmdb_builder.sh` tries to install Python 3.13 via `add-apt-repository ppa:deadsnakes/ppa`, which does not exist on Debian. The step fails but `psmdb_builder.sh` runs without `set -e` so the image still builds. Debian's stock Python 3.11 is sufficient for `buildscripts/install_bazel.py` (stdlib-only) and for a full `bazel build install-dist-test`. A proper fix (per-distro Python-3.13 strategy) is tracked in the roadmap and not required for the validation above.

## Strategy: run `install_deps()` from a locally-committed copy of `psmdb_builder.sh`

The single source of truth for build-time dependencies upstream is `install_deps()` in:

```
percona-server-mongodb/percona-packaging/scripts/psmdb_builder.sh
```

We keep a local copy of that script in this directory:

```
IaC/buildbarn/runners/psmdb_builder.sh   # shared across all variants
```

Every `Dockerfile` under `runners/<variant>/` copies this single file and runs it with `--install_deps=1` during image build. The local copy is currently a straight verbatim copy of upstream; BuildBarn-specific tweaks (e.g. skipping `install_mongodbtoolchain` and `aws_sdk_build` which are provided hermetically by Bazel in 8.3 / master) can be applied here as follow-up commits once the baseline PoC image is validated against upstream `install_deps()` behavior.

Keeping the copy in-tree means:

- one `git diff` review makes any BuildBarn-specific deviation visible
- upstream `psmdb_builder.sh` changes are brought in by a conscious `cp` + review step (not silently)
- editing the runner install list for a single variant is a one-file commit

The Dockerfile does exactly what `buildStage()` of `psmdb/jenkins/percona-server-for-mongodb-8.3.groovy` does for every Jenkins build, minus the second (real-build) invocation:

```dockerfile
RUN wget -q "<raw URL to IaC/buildbarn/runners/psmdb_builder.sh>" -O /tmp/psmdb_builder.sh \
 && bash -x /tmp/psmdb_builder.sh --builddir=/tmp/build --install_deps=1
```

The raw URL points at the current branch of this `jenkins-pipelines` repo. See _How the Dockerfile finds the script_ below for why we fetch over HTTP instead of `COPY`-ing from a local build context.

No script patching is required. Every downstream phase inside `psmdb_builder.sh` (`get_sources`, `build_tarball`, `build_srpm`, `build_rpm`, `build_deb`, `build_source_deb`) starts with an internal guard:

```bash
build_rpm(){
    if [ $RPM = 0 ]
    then
        echo "RPM will not be created"
        return;
    fi
    ...
}
```

All flags (`SRPM`, `SDEB`, `RPM`, `DEB`, `SOURCE`, `TARBALL`) default to `0`. With only `--install_deps=1` passed, every build phase returns immediately — only `install_deps()` executes. This is the same pattern Jenkins relies on in `buildStage`:

```groovy
bash -x ./psmdb_builder.sh --builddir=${build_dir}/test --install_deps=1
```

### Why this instead of hand-curated Dockerfiles

| Concern | Hand-curated list | `psmdb_builder.sh install_deps()` |
|---------|-------------------|-----------------------------------|
| Drift from Jenkins build env | Has to be tracked manually on every `install_deps` change | Zero — same code path |
| What to include / exclude | Requires deep understanding of Bazel hermeticity | Not our concern — whatever install_deps does, runner gets |
| Adding a new OS variant | Transcribe all packages + helper steps | Copy dir, change `FROM` + `PSMDB_BRANCH` |
| Image size | Smaller (trimmed) | Larger (includes Go, toolchain v4, AWS SDK, curl-from-source) |

For the PoC stage we accept larger images. If size becomes a problem once all 11 variants are running, we can add a second stage that copies only the needed paths from a builder image. For now, correctness ≫ size.

## Naming

```
psmdb-runner-<os-codename>-<arch>:<tag>
```

Examples:

- `psmdb-runner-ubuntu-noble-x86_64:20260415`
- `psmdb-runner-ol8-x86_64:20260415`
- `psmdb-runner-ol9-aarch64:20260415`

Tags are date-stamped (`YYYYMMDD`) so each weekly rebuild is addressable. `:latest` and `:poc` are used only during development — production BuildBarn worker configs must pin to a dated tag to prevent silent drift between nodes.

## Directory layout

```
IaC/buildbarn/runners/
├── README.md                                  # this file
├── psmdb_builder.sh                           # shared, BuildBarn-tuned mirror of upstream
├── ubuntu-noble-x86_64/        Dockerfile     # validated, production PoC
├── ubuntu-noble-aarch64/       Dockerfile     # matrix entry; first build pending GHA
├── ubuntu-jammy-x86_64/        Dockerfile
├── ubuntu-jammy-aarch64/       Dockerfile
├── debian-bookworm-x86_64/     Dockerfile     # validated, second pool PoC
├── oraclelinux-8-x86_64/       Dockerfile     # covers 4 Jenkins stages (rpm + tarball + source rpm + source tarball)
├── oraclelinux-8-aarch64/      Dockerfile
├── oraclelinux-9-x86_64/       Dockerfile
├── oraclelinux-9-aarch64/      Dockerfile
├── amazonlinux-2023-x86_64/    Dockerfile
└── amazonlinux-2023-aarch64/   Dockerfile

.github/workflows/
└── build-psmdb-buildbarn-runners.yml          # matrix-builds all 11; triggers: push to runners/**, workflow_dispatch, weekly cron
```

Note: no Debian Bookworm aarch64 — the PSMDB 8.3 Jenkins pipeline does not have that stage, so we don't carry an unused runner image. See `../buildbarn-ondemand-scaler.md` §3.1 for the full mapping of runners to Jenkins stages and to MongoDB's `REMOTE_EXECUTION_CONTAINERS` keys.

Every Dockerfile differs from `ubuntu-noble-x86_64/Dockerfile` in only:

- `FROM <distro>:<version>` — Ubuntu / Debian / Oracle Linux / Amazon Linux base image
- package-manager bootstrap line (`apt-get install wget` vs `dnf install wget`)
- three `LABEL org.percona.psmdb.{os,glibc,arch}=...` lines

`install_deps()` itself auto-detects the OS via `get_system()` (checks `/etc/redhat-release`, `/etc/amazon-linux-release`, else Debian) and picks the right branch — no per-Dockerfile logic required.

### How the Dockerfile finds the script

Rather than `COPY`-ing `psmdb_builder.sh` from a local build context, each `Dockerfile` fetches it over HTTP from the current branch of this repo (`jenkins-pipelines`) using `wget` — same pattern as Jenkins `buildStage`:

```dockerfile
ARG JENKINS_PIPELINES_REPO=https://github.com/vorsel/jenkins-pipelines.git
ARG JENKINS_PIPELINES_BRANCH=PSMDB-2034_buildbarn_setup
ARG PSMDB_BUILDER_SCRIPT_PATH=IaC/buildbarn/runners/psmdb_builder.sh
ARG CACHE_BUST=0

RUN RAW_URL="$(echo ${JENKINS_PIPELINES_REPO} \
                | sed -re 's|github.com|raw.githubusercontent.com|; s|\.git$||')/${JENKINS_PIPELINES_BRANCH}/${PSMDB_BUILDER_SCRIPT_PATH}" \
 && wget -q "${RAW_URL}" -O /tmp/psmdb_builder.sh \
 && bash -x /tmp/psmdb_builder.sh --builddir=/tmp/build --install_deps=1
```

Rationale:

- Images are built on remote BuildBarn worker nodes that do not have a checkout of `jenkins-pipelines`. A `COPY`-based flow would require shipping the repo as build context over SSH on every rebuild.
- During PoC iteration we tweak `psmdb_builder.sh` frequently. `wget` + `--build-arg CACHE_BUST=$(date +%s)` forces a fresh download on every `docker build`, so the layer is never stale.
- Once the script stabilizes, we push the final version back into `percona-server-mongodb/percona-packaging/scripts/psmdb_builder.sh` and switch the `PSMDB_BUILDER_SCRIPT_PATH` ARG to point at the upstream raw URL instead.

### Keeping the copy in sync with upstream

When `percona-server-mongodb/percona-packaging/scripts/psmdb_builder.sh` changes upstream, refresh the local copy:

```bash
# From repo root
cp percona-server-mongodb/percona-packaging/scripts/psmdb_builder.sh \
   jenkins-pipelines/IaC/buildbarn/runners/psmdb_builder.sh

cd jenkins-pipelines
git diff IaC/buildbarn/runners/psmdb_builder.sh
# commit + push: the next runner image build will fetch this revision
```

## Building on a worker node (PoC workflow)

```bash
ssh root@barn-psmdb-worker-2
mkdir -p /tmp/psmdb-runner-build
cd /tmp/psmdb-runner-build

# Fetch just the Dockerfile (the script is pulled by wget inside the build)
wget -q https://raw.githubusercontent.com/vorsel/jenkins-pipelines/PSMDB-2034_buildbarn_setup/IaC/buildbarn/runners/ubuntu-noble-x86_64/Dockerfile

# Build — CACHE_BUST forces a fresh wget of psmdb_builder.sh even if the
# Dockerfile itself has not changed
docker build \
    --build-arg CACHE_BUST=$(date +%s) \
    -t psmdb-runner-ubuntu-noble-x86_64:poc \
    -f Dockerfile .

# Deploy on this one worker node as a control experiment — leave the
# other nodes on psmdb-runner:latest to compare build times side-by-side
cd /opt/buildbarn
cp docker-compose.yml docker-compose.yml.bak-$(date +%Y%m%d)
sed -i 's|psmdb-runner:latest|psmdb-runner-ubuntu-noble-x86_64:poc|' docker-compose.yml
docker compose down && docker compose up -d
docker compose logs worker --tail 30
```

Then run a PSMDB build from the client and compare wall time and any compilation errors against the `psmdb-runner:latest` baseline (30 min cold, 2 min 47 s warm — see Part 9.7 of the main setup guide).

## Using the image in BuildBarn permanently

Once a tagged image is verified on one worker:

1. Build the same tag on every worker node (or push to a shared registry once one is chosen — see Part 11.4 of the main setup guide)
2. Update `docker-compose.yml` on each node to reference the dated tag
3. Update `platform.properties.container-image` in the worker config so the Bazel client-side `--remote_default_exec_properties` sees a matching property if we decide to split per-variant pools

For the PoC we keep platform properties identical to the existing `psmdb-runner:latest` setup — only the on-disk image changes, so the PSMDB build does not need any client-side flags.

## Rebuild cadence and triggers

GitHub Actions workflow: [`.github/workflows/build-psmdb-buildbarn-runners.yml`](../../../.github/workflows/build-psmdb-buildbarn-runners.yml). Triggers:

- `push` to `main` or `PSMDB-2034_buildbarn_setup` touching `IaC/buildbarn/runners/**` or the workflow file — rebuilds any variants whose Dockerfile or shared `psmdb_builder.sh` changed (matrix rebuilds everything; `CACHE_BUST=$(date +%s)` ensures `install_deps()` re-runs against the current `psmdb_builder.sh`).
- `schedule: cron "0 3 * * 1"` — weekly Monday 03:00 UTC rebuild. Covers CVE updates in base OS packages and in MongoDB toolchain downloads without daily churn.
- `workflow_dispatch` — manual run; supports `variants` input (space-separated subset of the 11) for targeted rebuilds and `push_latest` toggle for branch experiments.

Each matrix job produces two tags on `ghcr.io/<owner>/psmdb-buildbarn-runners/<variant>`:

- `:${{ github.sha }}` — immutable, what BuildBarn worker configs pin in production.
- `:latest` and `:<branch-name>` — moving tags for local iteration and for the on-demand scaler's `container-image` pool property during dev.

aarch64 variants build natively on GitHub-hosted ARM runners (`ubuntu-24.04-arm`, free tier for public repos) — avoids 10–20x QEMU emulation overhead.
