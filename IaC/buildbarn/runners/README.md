# BuildBarn Runner Images for PSMDB

Each subdirectory holds a `Dockerfile` for one `(OS, glibc, arch)` combination from the PSMDB release matrix. Images are consumed by BuildBarn runners (`runner-*` service in `docker-compose.yml`) and referenced by the worker `platform.properties.container-image` field.

## Status

| Variant | Status | Validation evidence |
|---------|--------|---------------------|
| `ubuntu-noble-x86_64/` | **Production (PoC tag `:poc`)** on all hardlinking-pool nodes of the BuildBarn cluster | 10,330 remote executions with zero action failures on `install-dist-test`, measured with `--noremote_accept_cached` on a heterogeneous cluster (see §9.7 of `../buildbarn-remote-execution-setup.md`) |
| all other variants | Not yet implemented | — |

Image size for the PoC variant is ~1.73 GB on disk / 441 MB content. This is intentionally larger than strictly necessary because `psmdb_builder.sh install_deps()` also installs Go SDK, `valgrind`, `devscripts`/`debhelper`, and pip bootstrap — none of which Bazel uses at runtime (Bazel pulls the hermetic `mongo_toolchain_v5` from CAS). Commenting those blocks in the local `psmdb_builder.sh` copy is a pending size-reduction follow-up; until it lands, correctness ≫ size.

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

For the PoC stage we accept larger images. If size becomes a problem once all 17 variants are running, we can add a second stage that copies only the needed paths from a builder image. For now, correctness ≫ size.

## Naming

```
psmdb-runner-<os-codename>-<arch>:<tag>
```

Examples:

- `psmdb-runner-ubuntu-noble-x86_64:20260415`
- `psmdb-runner-ol8-x86_64:20260415`
- `psmdb-runner-ol9-aarch64:20260415`

Tags are date-stamped (`YYYYMMDD`) so each weekly rebuild is addressable. `:latest` and `:poc` are used only during development — production BuildBarn worker configs must pin to a dated tag to prevent silent drift between nodes.

## Directory layout (target)

```
IaC/buildbarn/runners/
├── README.md                          # this file
├── psmdb_builder.sh                   # shared, BuildBarn-tuned mirror of upstream
├── ubuntu-noble-x86_64/               # PoC (step 2 of roadmap)
│   └── Dockerfile
├── ubuntu-jammy-x86_64/
├── ubuntu-jammy-aarch64/
├── ubuntu-noble-aarch64/
├── debian-bookworm-x86_64/
├── oracle-linux-8-x86_64/
├── oracle-linux-8-aarch64/
├── oracle-linux-9-x86_64/
├── oracle-linux-9-aarch64/
├── amazon-linux-2023-x86_64/
├── amazon-linux-2023-aarch64/
└── .github/workflows/
    └── weekly-rebuild.yml             # pushes all variants to registry
```

Only `ubuntu-noble-x86_64/` is implemented today (PoC). Every subsequent variant is produced by creating a one-file subdirectory with a `Dockerfile` that differs in only one line:

- `FROM <distro>:<version>` — Ubuntu / Debian / Oracle Linux / Amazon Linux base image

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

## Planned rebuild cadence

Weekly, triggered by GitHub Actions (`weekly-rebuild.yml`). Justification: covers security updates to base OS packages and to MongoDB toolchain downloads without daily churn. Ad-hoc rebuild when `psmdb_builder.sh install_deps()` changes upstream (detected via CI watching `percona-server-mongodb` `master` + `preview-*` branches).
