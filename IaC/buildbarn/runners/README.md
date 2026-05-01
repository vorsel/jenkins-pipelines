# BuildBarn Runner Images for PSMDB

Each subdirectory holds a `Dockerfile` for one `(OS, glibc, arch)` combination from the PSMDB release matrix. Images are consumed by BuildBarn runners (`runner-*` service in `docker-compose.yml`) and referenced by the worker `platform.properties.container-image` field.

## Status

Currently **Phase 1 (PoC)** — see [Phased migration plan](#phased-migration-plan) below. Phase 2 (source-of-truth → percona-server-mongodb) and Phase 3 (codegen sync of image tags) are designed but not yet implemented.

The 11-variant × 3-version matrix is the authoritative list from `../buildbarn-ondemand-scaler.md` §3.1, which in turn mirrors the parallel stages in `psmdb/jenkins/percona-server-for-mongodb-8.3.groovy`. GHA workflow `.github/workflows/build-psmdb-buildbarn-runners.yml` builds all 11 × 3 = 33 combinations in one run and pushes each to `ghcr.io/<owner>/psmdb-buildbarn-runners/<variant>:<version>-<sha>` (immutable) and `ghcr.io/<owner>/psmdb-buildbarn-runners/<variant>:<version>` (moving).

The three PSMDB release lines are **`8.0`**, **`8.3`**, and **`master`** — one `psmdb_builder_<version>.sh` copy per line in this directory. Each image repo (e.g. `ubuntu-noble-x86_64`) therefore carries three parallel tag streams, one per release line, so BuildBarn worker configs can pin a variant to a specific PSMDB version without branching the image repo.

| Variant | Status | Validation evidence |
|---------|--------|---------------------|
| `ubuntu-noble-x86_64/` | **Production (PoC tag `:poc`)** on all hardlinking-pool nodes of the BuildBarn cluster | 10,330 remote executions with zero action failures on `install-dist-test`, measured with `--noremote_accept_cached` on a heterogeneous cluster (see §9.7 of `../buildbarn-remote-execution-setup.md`) |
| `debian-bookworm-x86_64/` | **Validated** as a second pool (`debian12`) on `barn-psmdb-worker-2`; full cold `install-dist-test` completed | Cold build: 10,330 remote executions, exit 0, 1 h 43 min 42 s wall time (includes OOM+swap recovery mid-build). Identical `gitVersion` and `perconaFeatures` vs noble; different `openSSLVersion` (Debian 3.0.19 vs Ubuntu 3.0.13) proves per-distro runtime libs resolve correctly — see §9.7 "Second variant" in `../buildbarn-remote-execution-setup.md` |
| `ubuntu-jammy-x86_64/`, `ubuntu-jammy-aarch64/`, `ubuntu-noble-aarch64/`, `oraclelinux-8-x86_64/`, `oraclelinux-8-aarch64/`, `oraclelinux-9-x86_64/`, `oraclelinux-9-aarch64/`, `amazonlinux-2023-x86_64/`, `amazonlinux-2023-aarch64/` | **Dockerfile committed; first image build pending GHA run** | `install_deps()` for each of these docker bases (`oraclelinux:8`, `oraclelinux:9`, `amazonlinux:2023`, `ubuntu:jammy`) has been executing on every Jenkins PSMDB 8.3 matrix build for years (see `buildStage(...)` in `psmdb/jenkins/percona-server-for-mongodb-8.3.groovy`). Empirical per-variant validation happens on first GHA run of `.github/workflows/build-psmdb-buildbarn-runners.yml` |

Image sizes: `ubuntu-noble-x86_64:poc` ~1.73 GB on disk / 441 MB content. `debian-bookworm-x86_64:poc` ~2.17 GB / 615 MB. Both are intentionally larger than strictly necessary because `psmdb_builder.sh install_deps()` installs Go SDK, `valgrind`, `devscripts`/`debhelper`, and pip bootstrap — none of which Bazel uses at runtime (Bazel pulls the hermetic `mongo_toolchain_v5` from CAS). Commenting those blocks in the local `psmdb_builder_<version>.sh` copies is a pending size-reduction follow-up; until it lands, correctness ≫ size.

**Known non-fatal warning on Debian:** `psmdb_builder.sh` tries to install Python 3.13 via `add-apt-repository ppa:deadsnakes/ppa`, which does not exist on Debian. The step fails but `psmdb_builder.sh` runs without `set -e` so the image still builds. Debian's stock Python 3.11 is sufficient for `buildscripts/install_bazel.py` (stdlib-only) and for a full `bazel build install-dist-test`. A proper fix (per-distro Python-3.13 strategy) is tracked in the roadmap and not required for the validation above.

## Phased migration plan

The current shape of this directory (per-version `psmdb_builder_*.sh` copies
committed here) is **Phase 1 — PoC**. Two follow-up phases are planned and
recorded here so the next operator can pick up where we left off. The rest
of this README still describes the Phase-1 architecture in detail; it will
be rewritten incrementally as each phase lands.

### Phase 1 — PoC (current state)

| Aspect | Value |
|---|---|
| Status | DONE — production-validated on `ubuntu-noble-x86_64:poc` (10,330 remote actions, 0 failures), `debian-bookworm-x86_64:poc` (cold `install-dist-test` complete) |
| Script source | `IaC/buildbarn/runners/psmdb_builder_{8_0,8_3,master}.sh` (3 checked-in copies) |
| Dockerfile fetch URL | jenkins-pipelines raw GitHub URL, branch parameterized via ARG |
| Image tag SHA | `${{ github.sha }}` of jenkins-pipelines (the commit that triggered the GHA workflow) |
| Synchronization to upstream | Manual `cp` from each `mongo:<branch>:percona-packaging/scripts/psmdb_builder.sh`, hand-applied BuildBarn tweaks per release line, then commit to jenkins-pipelines |

Phase-1 trade-off: the three copies inevitably drift from upstream (a `diff
mongo:v8.0:percona-packaging/scripts/psmdb_builder.sh
jenkins-pipelines:IaC/buildbarn/runners/psmdb_builder_8_0.sh` already
shows divergence). Acceptable while the PoC is rapidly iterating; not
sustainable in production.

### Phase 2 — Source-of-truth migration to percona-server-mongodb (NEXT)

**Goal**: stop maintaining a fork of `psmdb_builder.sh` in jenkins-pipelines.
Have image builds fetch the script directly from the matching
percona-server-mongodb branch.

**Trade-off summary**:

| | Phase 1 (today) | Phase 2 |
|---|---|---|
| Script location | jenkins-pipelines: `IaC/buildbarn/runners/psmdb_builder_<version>.sh` (3 copies) | percona-server-mongodb: `percona-packaging/scripts/psmdb_builder.sh` (1 file × 3 branches, upstream-owned) |
| Dockerfile wget URL | `https://raw.githubusercontent.com/vorsel/jenkins-pipelines/<branch>/IaC/buildbarn/runners/psmdb_builder_<version>.sh` | `https://raw.githubusercontent.com/<percona-mongo-org>/percona-server-mongodb/<v8.0\|v8.3\|master>/percona-packaging/scripts/psmdb_builder.sh` |
| Image tag SHA semantics | jenkins-pipelines commit SHA | SHA of the **last mongo commit that touched** `percona-packaging/scripts/psmdb_builder.sh` on the matching branch (NOT branch HEAD — see "Rebuild trigger logic" below) |
| Per-rotation operator work in this repo | edit `psmdb_builder_<v>.sh`, push, GHA rebuilds | none — daily cron in jenkins-pipelines GHA detects `psmdb_builder.sh` change in any of the three mongo branches and rebuilds only the variants whose script actually changed; operator can also force-trigger via `workflow_dispatch` |

**Concrete file changes** (one atomic PR):

In jenkins-pipelines:

- **DELETE** `IaC/buildbarn/runners/psmdb_builder_8_0.sh`, `psmdb_builder_8_3.sh`, `psmdb_builder_master.sh` (3 files)
- **EDIT** 13 Dockerfiles in `IaC/buildbarn/runners/<distro>-<arch>/`:
  - Replace `JENKINS_PIPELINES_REPO`, `JENKINS_PIPELINES_BRANCH`, `PSMDB_BUILDER_SCRIPT_PATH` ARGs with `MONGO_REPO`, `MONGO_BRANCH`, and a hardcoded path `percona-packaging/scripts/psmdb_builder.sh`
  - Dockerfile defaults: `MONGO_REPO=https://github.com/Percona-Lab/percona-server-mongodb.git` (long-term target). The GHA workflow visibly overrides via `--build-arg MONGO_REPO=https://github.com/vorsel/percona-server-mongodb.git` until the upstream merge into Percona-Lab lands; that single override line gets deleted post-merge. Default `MONGO_BRANCH=v8.3` (matches existing `PSMDB_VERSION=8.3` default semantics)
- **EDIT** `.github/workflows/build-psmdb-buildbarn-runners.yml`:
  - Drop `paths:` trigger entry for `runners/psmdb_builder_*.sh` (those files won't exist)
  - **Triggers** (Q2c — daily cron + manual):
    - `schedule: cron "0 3 * * *"` (daily 03:00 UTC) — replaces the weekly Phase-1 cron; bounds latency from script-merge in mongo to fresh image at ≤24 h
    - `workflow_dispatch` with inputs `versions` (subset of `8.0 8.3 master`) and `variants` (subset of 11 distros) — for forced rebuilds (e.g. dev who just merged an `install_deps` change in mongo and doesn't want to wait for cron)
    - `push` on `main`/`PSMDB-2034_buildbarn_setup` touching `IaC/buildbarn/runners/**` or the workflow file (covers Dockerfile / workflow edits in this repo)
  - Add a small mapping in the detect-changes job: `8.0`→`v8.0`, `8.3`→`v8.3`, `master`→`master`
  - **Resolve last-script-touch SHA per branch** (Q1a):
    ```
    gh api "repos/<owner>/percona-server-mongodb/commits?path=percona-packaging/scripts/psmdb_builder.sh&sha=<branch>&per_page=1" --jq '.[0].sha'
    ```
    Returns SHA of the most recent mongo commit on `<branch>` that touched `psmdb_builder.sh`. Stays constant while the branch advances on commits that don't touch the script.
  - **Skip-if-tag-exists**: before launching the build for `(distro, branch, sha)`, query GHCR for `<distro>:<branch>-<sha>`. If it already exists, mark the matrix cell as skipped — same `(distro, branch, sha)` tuple already produced an immutable image. Only Dockerfile / GHA-workflow edits in this repo bypass this check (those legitimately need rebuild even with an unchanged script SHA — handled by `push`-trigger path which carries `force=true`).
  - Use the resolved mongo last-script-touch SHA as the image tag suffix (instead of `${{ github.sha }}`)
  - Pass `MONGO_REPO`, `MONGO_BRANCH`, and the resolved SHA into Docker as `--build-arg`s
  - Add `concurrency: group: build-psmdb-buildbarn-runners-<psmdb_version>, cancel-in-progress: false` so two simultaneous rotations of the same release line serialize
- **EDIT** this README:
  - Replace "Strategy: run install_deps() from per-version BuildBarn-tuned copies" section with a "Strategy: fetch from upstream mongo branches" rewrite
  - Remove `psmdb_builder_*.sh` entries from "Directory layout"
  - Replace "Keeping the copies in sync with upstream" section with "No syncing required — push commit to mongo branch, dispatch GHA"

In percona-server-mongodb: **zero changes**. `psmdb_builder.sh` already lives at `percona-packaging/scripts/psmdb_builder.sh` on `v8.0`, `v8.3`, `master`. The mongo side simply becomes the canonical source.

**Race conditions and mitigations**:

| Race | Scenario | Mitigation |
|---|---|---|
| R1: mongo branch HEAD moves during image build | Not a race in Phase 2: image tag suffix is the **last-script-touch SHA**, not branch HEAD. Branch HEAD can advance to commit Y mid-build with no effect — Y didn't touch the script, so `gh api commits?path=psmdb_builder.sh` still returns the same SHA. | None needed. (`concurrency: group: build-psmdb-buildbarn-runners-<psmdb_version>` is still kept for hygiene against simultaneous `workflow_dispatch` + cron firing.) |
| R2: SHA-resolve API call fails or returns stale value | GitHub API rate-limit or transient error. | Retry once with 10 s back-off; on second failure, fail fast — incorrect SHA in the image tag is worse than no build. |
| R3: GHA workflow runs from `vorsel` fork while `MONGO_REPO` defaults to `Percona-Lab` | Dockerfile pulls from a repo that doesn't exist yet (pre-upstream). | GHA explicit `--build-arg MONGO_REPO=https://github.com/vorsel/percona-server-mongodb.git` until upstream merge. Delete that line in a one-commit follow-up the moment upstream lands. |
| R4: mongo branch is private or requires auth | Future: if mongo repo goes private. | Out of scope for Phase 2; would require a deploy key or App token plumbed through the Dockerfile build. Current `vorsel` and `Percona-Lab` mirrors are public, so `wget` over plain HTTPS works. |
| R5: two `psmdb_builder.sh`-touching commits land within the same cron window | Cron runs at 03:00 UTC, sees commit X. Operator merges another script-touching commit Y at 04:00. Until next cron run, GHCR reflects only `:<branch>-X`, the cluster still pulls X. | Daily cron + on-demand `workflow_dispatch` covers this — the merger of Y triggers the build manually. Phase-3 webhook (see L1.5 below) eliminates the gap entirely by reacting to the merge event in real time. |

**Acceptance gate (Phase 2 → DONE)**:

- One full `workflow_dispatch` run rebuilds all 33 jobs successfully against the new Dockerfile/workflow shape
- Output image tags follow `<distro>:<version>-<last-script-touch-sha>` where the suffix matches the output of `gh api "repos/<owner>/percona-server-mongodb/commits?path=percona-packaging/scripts/psmdb_builder.sh&sha=<branch>&per_page=1" --jq '.[0].sha'` at build start
- A second `workflow_dispatch` run **immediately** after the first completes with **all 33 jobs skipped** (no rebuild because tag already exists in GHCR). Confirms skip-if-tag-exists logic works.
- After a no-op mongo commit on `v8.0` (e.g. doc-only change that does NOT touch `psmdb_builder.sh`), the next cron run produces zero rebuilds for the 11 `v8.0` variants.
- After a real `psmdb_builder.sh` change on `v8.0`, the next cron run produces exactly 11 new images (one per distro × arch for `v8.0`), tagged with the new SHA, while `v8.3` and `master` variants stay untouched.
- The 3 deleted `psmdb_builder_*.sh` files are not referenced by any remaining file in jenkins-pipelines (`grep -r psmdb_builder_ IaC/ .github/` returns 0 hits)
- A subsequent Bazel build with `--config=psmdb_buildfarm` against the new image tag succeeds end-to-end (RBE handshake validates, action cache invalidation works as expected)

**Rebuild trigger logic** (the heart of Phase 2 — Q1a + Q2c):

The cron-driven detect-changes job reduces wasted GHA minutes by rebuilding only when the script actually changed. Pseudocode:

```bash
# detect-changes job (runs first, outputs matrix for the build job)
for psmdb_version in 8.0 8.3 master; do
  case "$psmdb_version" in
    8.0)    branch=v8.0 ;;
    8.3)    branch=v8.3 ;;
    master) branch=master ;;
  esac

  # Q1a — last-script-touch SHA, NOT branch HEAD
  sha=$(gh api "repos/${MONGO_OWNER}/percona-server-mongodb/commits?path=percona-packaging/scripts/psmdb_builder.sh&sha=${branch}&per_page=1" \
        --jq '.[0].sha')

  for distro_arch in ubuntu-noble-x86_64 debian-bookworm-x86_64 ...; do
    tag="${psmdb_version}-${sha}"
    if gh api "users/${REGISTRY_OWNER}/packages/container/psmdb-buildbarn-runners%2F${distro_arch}/versions" \
       --jq '.[].metadata.container.tags[]' | grep -qx "$tag"; then
      echo "skip ${distro_arch}:${tag} — already in GHCR"
      continue
    fi
    matrix_jobs+=("{distro_arch:${distro_arch},branch:${branch},sha:${sha}}")
  done
done
```

The build job then runs only on `matrix_jobs`. With unchanged scripts: 0 images built (cron is essentially free). With one changed branch: exactly 11 images (one per distro × arch for that branch) — the other 22 cells skip.

The `push`-trigger code path (Dockerfile or workflow edits in this repo) carries `force=true` to bypass the skip-if-tag-exists check — those edits legitimately invalidate previously-built images even when the script SHA is unchanged.

**What is intentionally NOT in Phase 2**:

- Webhook from mongo repo on script change → real-time push trigger. Deferred to Phase 3 L1.5 because it requires either a GitHub App or a cross-repo PAT (same secret-management work as Phase 3 codegen auto-PR), so we land both pieces at once when that infrastructure is in place.
- Codegen of `psmdb_rbe_containers.bzl` and `ondemand-pools.yaml` from a canonical YAML. That's Phase 3 — Phase 2 keeps the existing dual-edit cycle (mongo `psmdb_rbe_containers.bzl` × 3 branches + jenkins-pipelines `ondemand-pools.yaml`); only the script source moves.

**Migration mode**: single atomic PR. Tested via `workflow_dispatch` before merge. Revert = single commit revert. The `runner-images.yaml` source-of-truth file from Phase 3 is **not** introduced here.

### Phase 3 — Single-source-of-truth + codegen sync (FOLLOWS PHASE 2)

**When to start**: after Phase 2 is stable for ≥2 consecutive successful image rotations validated end-to-end (i.e. we have empirical evidence the mongo-as-source flow works).

**Problem after Phase 2 lands**:

Image rotation still requires four manually-edited files to agree byte-for-byte on the image tag string (REAPI Platform property is matched exactly by bb-scheduler):

- `IaC/buildbarn/ondemand/compose/config/ondemand-pools.yaml` — 1 file in jenkins-pipelines
- `bazel/platforms/psmdb_rbe_containers.bzl` — 1 file × 3 branches in percona-server-mongodb (`master`, `v8.3`, `v8.0`)

Manual sync across 4 file edits in 2 repos = error-prone and slow.

**Proposed mechanism — single canonical YAML + Python codegen + auto-PR**:

```
jenkins-pipelines/
├── IaC/buildbarn/runner-images.yaml      # canonical source of truth
└── scripts/sync-runner-images.py         # codegen tool (~50 lines, stdlib only)
```

Canonical YAML shape:

```yaml
registry: ghcr.io/vorsel/psmdb-buildbarn-runners   # placeholder; updates per migration to Percona-controlled GHCR org
branches:
  master:
    sha: <mongo-master-head>
    distros: [amazon_linux_2023, debian12, rhel8, rhel9, ubuntu22, ubuntu24]
  v8.3:
    sha: <mongo-v8.3-head>
    distros: [...]
  v8.0:
    sha: <mongo-v8.0-head>
    distros: [...]
```

`sync-runner-images.py` reads this YAML and regenerates:

- `IaC/buildbarn/ondemand/compose/config/ondemand-pools.yaml` (in cwd jenkins-pipelines)
- `bazel/platforms/psmdb_rbe_containers.bzl` per mongo branch — `git checkout <branch>` in a mongo working tree → write generated `.bzl` → `git commit -m "PSMDB-2034 buildbarn: bump runner image to <sha> (autogen)"`

**Automation level — staged**:

| Level | Description | Status |
|---|---|---|
| L0 (today) | Fully manual edit of 4 files. | Phase 1+2 default |
| L1 (target initial) | GHA in jenkins-pipelines opens auto-PR for jenkins-pipelines side after image build. Operator runs sync-script locally to update mongo branches, opens 3 PRs by hand. No cross-repo PAT/secrets needed. | First Phase 3 milestone |
| L1.5 (mongo→jenkins-pipelines webhook) | GHA in **percona-server-mongodb** (one workflow per release branch, triggered on `push` to `percona-packaging/scripts/psmdb_builder.sh`) sends `repository_dispatch` event of type `psmdb-builder-changed` to jenkins-pipelines, with `client_payload: {branch, sha}`. jenkins-pipelines workflow listens to that event and rebuilds the affected 11 variants in real time — eliminates the ≤24 h cron latency from R5 and the need for `workflow_dispatch` after every script-touching merge. Requires PAT or GitHub App with `repository_dispatch` write scope on jenkins-pipelines. Cron stays as a safety net (catches missed webhooks). | After L1 has stabilized; bundled with L2's secret-management work |
| L2 (target stable) | GHA additionally clones percona-server-mongodb (using PAT or GitHub App) and opens 3 auto-PRs against mongo branches. | Once L1 has stabilized over ~3 rotations |

**L1 → L2 escalation criteria**:

- Operator workflow on L1 has been used for ≥3 successful rotations with no manual override
- Cross-repo write access is available — either PAT in `PSMDB_AUTOSYNC_TOKEN` secret, or a GitHub App `psmdb-buildbarn-bot` installed on both repos (preferred)
- Branch protection on mongo `v8.0`/`v8.3`/`master` is configured to require ≥1 reviewer on auto-PRs to prevent merge-before-jenkins-pipelines-PR race

**Race conditions specific to Phase 3**:

| Race | Mitigation |
|---|---|
| Mongo PR merged before jenkins-pipelines PR (in L2) — runtime sees Bazel sending new image tag while bb-scheduler still has the old pool registered → `FAILED_PRECONDITION` until jenkins-pipelines PR merges | jenkins-pipelines auto-PR title prefixed `[BLOCKER]`, mongo auto-PR description explicitly says `DO NOT MERGE BEFORE jenkins-pipelines PR <link>`. Not fully bullet-proof — branch protection + reviewer convention is the operational backstop. |
| Concurrent rotations clobber each other's auto-PR branch | `concurrency: group: runner-images-sync, cancel-in-progress: false` (carried over from Phase 2) |
| Hand-edit of generated `.bzl` or `ondemand-pools.yaml` | Generated files carry a `# AUTO-GENERATED — do not hand-edit. Source: jenkins-pipelines/IaC/buildbarn/runner-images.yaml` header. Next sync overwrites silently; reviewer expected to flag a hand-edit during PR review. |

**Acceptance gate (Phase 3 → DONE)**:

- Operator triggers rotation by editing one line (`sha:` value in `runner-images.yaml`)
- Running `python3 scripts/sync-runner-images.py --psmdb-checkout <path> --commit --write` regenerates all 4 downstream files; no further manual edits
- A minimum of 2 consecutive successful rotations through the new flow

**Status**: design only; implementation deferred until Phase 2 stabilizes. The architecture analysis (cross-repo PAT vs GitHub App, race conditions, automation levels) is documented above so the implementer doesn't have to redo it.

---

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
