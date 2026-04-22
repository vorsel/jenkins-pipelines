# BuildBarn Runner Images for PSMDB

Each subdirectory holds a `Dockerfile` for one `(OS, glibc, arch)` combination from the PSMDB release matrix. Images are consumed by BuildBarn runners (`runner-*` service in `docker-compose.yml`) and referenced by the worker `platform.properties.container-image` field.

## Status

The 11-variant × 3-version matrix is the authoritative list from `../buildbarn-ondemand-scaler.md` §3.1, which in turn mirrors the parallel stages in `psmdb/jenkins/percona-server-for-mongodb-8.3.groovy`. GHA workflow `.github/workflows/build-psmdb-buildbarn-runners.yml` builds all 11 × 3 = 33 combinations in one run and pushes each to `ghcr.io/<owner>/psmdb-buildbarn-runners/<variant>:<version>-<sha>` (immutable) and `ghcr.io/<owner>/psmdb-buildbarn-runners/<variant>:<version>` (moving).

The three PSMDB release lines are **`8.0`**, **`8.3`**, and **`master`** — one `psmdb_builder_<version>.sh` copy per line in this directory. Each image repo (e.g. `ubuntu-noble-x86_64`) therefore carries three parallel tag streams, one per release line, so BuildBarn worker configs can pin a variant to a specific PSMDB version without branching the image repo.

| Variant | Status | Validation evidence |
|---------|--------|---------------------|
| `ubuntu-noble-x86_64/` | **Production (PoC tag `:poc`)** on all hardlinking-pool nodes of the BuildBarn cluster | 10,330 remote executions with zero action failures on `install-dist-test`, measured with `--noremote_accept_cached` on a heterogeneous cluster (see §9.7 of `../buildbarn-remote-execution-setup.md`) |
| `debian-bookworm-x86_64/` | **Validated** as a second pool (`debian12`) on `barn-psmdb-worker-2`; full cold `install-dist-test` completed | Cold build: 10,330 remote executions, exit 0, 1 h 43 min 42 s wall time (includes OOM+swap recovery mid-build). Identical `gitVersion` and `perconaFeatures` vs noble; different `openSSLVersion` (Debian 3.0.19 vs Ubuntu 3.0.13) proves per-distro runtime libs resolve correctly — see §9.7 "Second variant" in `../buildbarn-remote-execution-setup.md` |
| `ubuntu-jammy-x86_64/`, `ubuntu-jammy-aarch64/`, `ubuntu-noble-aarch64/`, `oraclelinux-8-x86_64/`, `oraclelinux-8-aarch64/`, `oraclelinux-9-x86_64/`, `oraclelinux-9-aarch64/`, `amazonlinux-2023-x86_64/`, `amazonlinux-2023-aarch64/` | **Dockerfile committed; first image build pending GHA run** | `install_deps()` for each of these docker bases (`oraclelinux:8`, `oraclelinux:9`, `amazonlinux:2023`, `ubuntu:jammy`) has been executing on every Jenkins PSMDB 8.3 matrix build for years (see `buildStage(...)` in `psmdb/jenkins/percona-server-for-mongodb-8.3.groovy`). Empirical per-variant validation happens on first GHA run of `.github/workflows/build-psmdb-buildbarn-runners.yml` |

Image sizes: `ubuntu-noble-x86_64:poc` ~1.73 GB on disk / 441 MB content. `debian-bookworm-x86_64:poc` ~2.17 GB / 615 MB. Both are intentionally larger than strictly necessary because `psmdb_builder.sh install_deps()` installs Go SDK, `valgrind`, `devscripts`/`debhelper`, and pip bootstrap — none of which Bazel uses at runtime (Bazel pulls the hermetic `mongo_toolchain_v5` from CAS). Commenting those blocks in the local `psmdb_builder_<version>.sh` copies is a pending size-reduction follow-up; until it lands, correctness ≫ size.

**Known non-fatal warning on Debian:** `psmdb_builder.sh` tries to install Python 3.13 via `add-apt-repository ppa:deadsnakes/ppa`, which does not exist on Debian. The step fails but `psmdb_builder.sh` runs without `set -e` so the image still builds. Debian's stock Python 3.11 is sufficient for `buildscripts/install_bazel.py` (stdlib-only) and for a full `bazel build install-dist-test`. A proper fix (per-distro Python-3.13 strategy) is tracked in the roadmap and not required for the validation above.

## Strategy: run `install_deps()` from per-version BuildBarn-tuned copies

The single source of truth for build-time dependencies upstream is `install_deps()` in each PSMDB release branch:

```
percona-server-mongodb/percona-packaging/scripts/psmdb_builder.sh   on release-8.0
percona-server-mongodb/percona-packaging/scripts/psmdb_builder.sh   on release-8.3  (or preview-8.3.0-0)
percona-server-mongodb/percona-packaging/scripts/psmdb_builder.sh   on master
```

We keep one BuildBarn-tuned copy per release line in this directory:

```
IaC/buildbarn/runners/psmdb_builder_8_0.sh
IaC/buildbarn/runners/psmdb_builder_8_3.sh
IaC/buildbarn/runners/psmdb_builder_master.sh
```

The GHA workflow's matrix builds every `<distro, arch>` Dockerfile against every release line, passing the matching script path via `--build-arg PSMDB_BUILDER_SCRIPT_PATH=...`. Every Dockerfile accepts the ARG with an 8.3 default, so plain `docker build` without the arg still produces the current `:8.3-*` image line.

Today all three scripts are byte-for-byte identical (seeded from the 8.3 copy with its `install_mongodbtoolchain` tweak applied). They will diverge as 8.0 freezes, 9.0/master accumulate new deps, etc. BuildBarn-specific tweaks (e.g. skipping `aws_sdk_build` which is provided hermetically by Bazel) are applied per-file.

Keeping per-version copies in-tree means:

- one `git diff` review makes any BuildBarn-specific deviation visible per version
- upstream changes are pulled in by a conscious `cp` + review step per branch (not silently)
- editing the runner install list for a single variant × single version is a one-file commit
- the three tag streams can drift independently as release lines evolve

The Dockerfile does exactly what `buildStage()` of `psmdb/jenkins/percona-server-for-mongodb-8.3.groovy` does for every Jenkins build, minus the second (real-build) invocation:

```dockerfile
# $PSMDB_BUILDER_SCRIPT_PATH defaults to psmdb_builder_8_3.sh; the GHA workflow
# overrides it to _8_0.sh / _master.sh for the other two matrix dimensions.
RUN wget -q "<raw URL to IaC/buildbarn/runners/${PSMDB_BUILDER_SCRIPT_PATH}>" -O /tmp/psmdb_builder.sh \
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

For the PoC stage we accept larger images. If size becomes a problem once all 11 × 3 variants are running, we can add a second stage that copies only the needed paths from a builder image. For now, correctness ≫ size.

## Naming

Full image coordinate — two tag forms per `(runner, version)` cell:

```
ghcr.io/<owner>/psmdb-buildbarn-runners/<os-codename>-<arch>:<psmdb-version>-<git-sha>   # immutable
ghcr.io/<owner>/psmdb-buildbarn-runners/<os-codename>-<arch>:<psmdb-version>             # moving
```

where `<psmdb-version>` is one of `8.0`, `8.3`, `master`.

Examples:

- `ghcr.io/vorsel/psmdb-buildbarn-runners/debian-bookworm-x86_64:8.3` — moving, latest successful build for PSMDB 8.3.
- `ghcr.io/vorsel/psmdb-buildbarn-runners/ubuntu-noble-x86_64:8.3-c9304266...` — immutable; exact image that a production BuildBarn worker pins.
- `ghcr.io/vorsel/psmdb-buildbarn-runners/oraclelinux-9-aarch64:master` — moving, latest master build.

`:<version>` is the tag to reach for in dev and in the on-demand scaler's `container-image` pool property (where drift is fine — next VM spawn just picks up the newest). Production BuildBarn worker configs must pin to `:<version>-<sha>` to prevent silent drift between nodes.

## Directory layout

```
IaC/buildbarn/runners/
├── README.md                                  # this file
├── psmdb_builder_8_0.sh                       # BuildBarn-tuned mirror of upstream release-8.0
├── psmdb_builder_8_3.sh                       # BuildBarn-tuned mirror of upstream release-8.3 (current production copy)
├── psmdb_builder_master.sh                    # BuildBarn-tuned mirror of upstream master
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
└── build-psmdb-buildbarn-runners.yml          # matrix-builds 11 × 3 = 33 jobs; triggers: push to runners/**, workflow_dispatch, weekly cron
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
ARG PSMDB_VERSION=8.3
ARG PSMDB_BUILDER_SCRIPT_PATH=IaC/buildbarn/runners/psmdb_builder_8_3.sh
ARG CACHE_BUST=0

RUN RAW_URL="$(echo ${JENKINS_PIPELINES_REPO} \
                | sed -re 's|github.com|raw.githubusercontent.com|; s|\.git$||')/${JENKINS_PIPELINES_BRANCH}/${PSMDB_BUILDER_SCRIPT_PATH}" \
 && wget -q "${RAW_URL}" -O /tmp/psmdb_builder.sh \
 && bash -x /tmp/psmdb_builder.sh --builddir=/tmp/build --install_deps=1
```

The GHA workflow overrides `PSMDB_VERSION` and `PSMDB_BUILDER_SCRIPT_PATH` per matrix cell; a plain `docker build` without `--build-arg` defaults to the 8.3 line.

Rationale:

- Images are built on GHA runners (and occasionally on BuildBarn worker nodes during PoC) that do not have a checkout of `jenkins-pipelines`. A `COPY`-based flow would require shipping the repo as build context over SSH on every rebuild.
- During PoC iteration we tweak `psmdb_builder_<version>.sh` frequently. `wget` + `--build-arg CACHE_BUST=$(date +%s)` forces a fresh download on every `docker build`, so the layer is never stale.
- Once a release line's script stabilizes, we can push the final version back into `percona-server-mongodb/percona-packaging/scripts/psmdb_builder.sh` on that branch and repoint `PSMDB_BUILDER_SCRIPT_PATH` at the upstream raw URL instead — per-version migration, independently of the other two lines.

### Keeping the copies in sync with upstream

Each release branch of `percona-server-mongodb` has its own `percona-packaging/scripts/psmdb_builder.sh`. To refresh our BuildBarn-tuned mirror for one release line:

```bash
# From the repo root of a checkout of percona-server-mongodb on the right branch,
# e.g. `git switch release-8.0`
cp percona-server-mongodb/percona-packaging/scripts/psmdb_builder.sh \
   jenkins-pipelines/IaC/buildbarn/runners/psmdb_builder_8_0.sh
# similarly: release-8.3 -> psmdb_builder_8_3.sh, master -> psmdb_builder_master.sh

cd jenkins-pipelines
git diff IaC/buildbarn/runners/psmdb_builder_8_0.sh
# Re-apply BuildBarn tweaks (e.g. comment out install_mongodbtoolchain for RHEL)
# commit + push: the next runner image build will fetch this revision for the
# :8.0-* tag stream only, without touching :8.3-* or :master-*.
```

## Building on a worker node (PoC workflow)

```bash
ssh root@barn-psmdb-worker-2
mkdir -p /tmp/psmdb-runner-build
cd /tmp/psmdb-runner-build

# Fetch just the Dockerfile (the script is pulled by wget inside the build)
wget -q https://raw.githubusercontent.com/vorsel/jenkins-pipelines/PSMDB-2034_buildbarn_setup/IaC/buildbarn/runners/ubuntu-noble-x86_64/Dockerfile

# Build — CACHE_BUST forces a fresh wget of psmdb_builder_<version>.sh even if
# the Dockerfile itself has not changed. Override PSMDB_VERSION + script path
# to produce the 8.0 or master image; defaults are 8.3.
docker build \
    --build-arg CACHE_BUST=$(date +%s) \
    --build-arg PSMDB_VERSION=8.3 \
    --build-arg PSMDB_BUILDER_SCRIPT_PATH=IaC/buildbarn/runners/psmdb_builder_8_3.sh \
    -t psmdb-runner-ubuntu-noble-x86_64:8.3-poc \
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

- `push` to `main` or `PSMDB-2034_buildbarn_setup` touching `IaC/buildbarn/runners/**` or the workflow file — rebuilds all 33 (runner × version) combinations; `CACHE_BUST=$(date +%s)` ensures `install_deps()` re-runs against the current `psmdb_builder_<version>.sh`.
- `schedule: cron "0 3 * * 1"` — weekly Monday 03:00 UTC rebuild. Covers CVE updates in base OS packages and in MongoDB toolchain downloads without daily churn.
- `workflow_dispatch` — manual run; supports `variants` input (space-separated subset of the 11 runners), `versions` input (space-separated subset of `8.0 8.3 master`) for targeted rebuilds, and a `push_moving` toggle for isolated branch experiments that must not clobber the `:<version>` pointer.

Each matrix job produces two tags on `ghcr.io/<owner>/psmdb-buildbarn-runners/<runner>`:

- `:<version>-${{ github.sha }}` — immutable, what BuildBarn worker configs pin in production.
- `:<version>` — moving alias pointing at the most recent successful build; used by the on-demand scaler's `container-image` pool property during dev.

aarch64 variants build natively on GitHub-hosted ARM runners (`ubuntu-24.04-arm`, free tier for public repos) — avoids 10–20x QEMU emulation overhead.
