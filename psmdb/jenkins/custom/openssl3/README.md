# PSMDB tarball with external OpenSSL 3

Two jobs on psmdb.cd, AWS only:

- `hetzner-psmdb-openssl3-tarball` builds a PSMDB tarball linked against a given OpenSSL 3 (not bundled),
  glibc 2.28 baseline, plus a runtime-libs tarball, manifest and SBOMs, and uploads them to RepoCI.
- `hetzner-psmdb-openssl3-tarball-test` runs the same checks on every OS from `os-matrix.json`.

```
psmdb-openssl3-tarball.groovy / .yml        build
psmdb-openssl3-tarball-test.groovy / .yml   tests
os-matrix.json                              OS list: Docker image + AMI, networks per region
profiles/<name>.env                         runtime lib versions, source sha256, expected NEEDED
scripts/                                    everything the jobs run, usable by hand too
```

## Build

| Parameter | Default | |
|---|---|---|
| `PSMDB_TAG` | `psmdb-8.0.34-15` | needs `MONGO_OPENSSL_ROOT` support (8.0.34+), checked |
| `OPENSSL_VERSION` | `3.5.9` | |
| `OPENSSL_SHA256` | empty | empty = the `.sha256` published with the release |
| `PROFILE` | `openssl3-fips` | `profiles/<name>.env` |
| `ARCH` | `x86_64` | |
| `JIRA_TASK` | `CUSTOM000` | RepoCI path and TESTING dir |
| `RUN_TESTS`, `TEST_LEVEL` | true, `containers` | start the test job |

- Fresh `oraclelinux:8` every build, deps from `psmdb_builder.sh --install_deps=1` of the same tag.
- Runtime libs are built from source each time (~6-8 min), no cache.
- Bazel runs locally: RBE workers have no OpenSSL 3 under `MONGO_OPENSSL_ROOT`.
- Fails on: NEEDED != profile, any OpenSSL 1.1 dependency, glibc symbols newer than 2.28,
  unresolved libs, wrong OpenSSL in `mongod --version`.

Everything on RepoCI lives in one private dir with no sync to downloads:

```
/srv/UPLOAD/experimental/BUILDS/PSMDB_OPENSSL3_FIPS/
├── vendor-bundle.zip                         customer bundle for the tests, put there by hand
└── <JIRA_TASK>/<BUILD_NUMBER>/binary/tarball/  build output
```

Build output:

```
percona-server-mongodb-<ver>-<arch>.glibc2.28-openssl<ver>.tar.gz              + .sha256
percona-server-mongodb-<ver>-<arch>.glibc2.28-openssl<ver>-runtime-libs.tar.gz + .sha256
...manifest.json            versions, commit, NEEDED, min runtime OpenSSL, lib source hashes
...sbom.cdx.json, ...-runtime-libs.sbom.cdx.json
```

SBOMs sit next to the tarballs because they carry the tarball sha256.
Runtime-libs includes a customer README (install, `fipsinstall`, rseq) and `bin/openssl`.

## Tests

| Parameter | Default | |
|---|---|---|
| `UPLOAD_PATH` | from the build | |
| `LEVEL` | `containers` | `containers`, `containers+vms`, `vms` |
| `OS_LIST` | `all` | ids from the matrix, to rerun only some |
| `VENDOR_BUNDLE` | `/srv/UPLOAD/experimental/BUILDS/PSMDB_OPENSSL3_FIPS/vendor-bundle.zip` | customer bundle; empty = our libs only |
| `FORCE_ON_DEMAND` | false | |
| `PUBLISH_TO_TESTING` | false | copy to downloads `TESTING/issue-<JIRA_TASK>` after a full pass |

- A, containers: all OS images on the agent, a couple of minutes, host kernel.
- B, VMs: one EC2 VM per OS with its own kernel. Only after A passes.
  Catches the 6.19.0-7.0.13 kernel guard (`startup_check_rseq.cpp`), which a container can't;
  `verify_os.sh` counts that refusal (log id 12257600) as PASS.
- Each OS is its own parallel branch with `failFast: false`. A VM lost to a spot interruption
  is retried once on-demand, for that OS only.
- The vendor bundle goes from RepoCI to the agent and test VMs only: never S3, never archived.
- Logs: each OS prints its full log to the console as one block when it finishes
  (`===== <os> BEGIN | <container image or VM details>` ... `END | PASS/FAIL`): every mongod
  command line, its stdout and log, mapped libs, client and `s_client` output, the ldd diff.
  The same goes to artifacts: `results/<level>/NN-<os>.log`, `.tsv`, `NN-<os>.mongod/`.
  The summary at the end starts with a legend of all checks (`scripts/checks.txt`).

## AWS

No new credentials or network objects; the same ones PSMDB/PG molecule use.

- Creds: `moleculePbmJenkinsCreds()`, key pair `molecule-pkg-tests`.
- `os-matrix.json` `.networks`:
  - `us-west-2`: `subnet-07f71e1a3117a32f9` (psmdb.cd VPC), SG `molecule-vpc-08eb4de1376aba839`, private IP
  - `eu-central-1`: `subnet-0fad4db6fdd8025b6`, SG `molecule-vpc-02f8275fe220ec651`, public IP, OL only
- Tags: `iit-billing-tag=jenkins-psmdb-worker`, set at launch. The account's EC2 cleanup lambda
  kills instances without it after 10 min, and never touches ones with it, so cleanup is ours:
  VMs shut down after 90 min (terminate on shutdown) and `post` sweeps by `jenkins-build` tag.
- Build agent `docker-64gb` is spot (no on-demand label on psmdb.cd);
  the stage has `retry(conditions: [agent(), nonresumable()])`.

## AMIs

`scripts/ec2_vm.sh ami os-matrix.json x86_64 <id>` shows what a run would take, read-only.

- RHEL (PAYG `Hourly2-GP3`) is pinned to a minor: EUS rebakes of older minors make "newest" flip
  between them. Bump on a new minor.
- OL: Oracle stopped publishing AMIs (last OL8.9/OL9.3, Feb 2024, now deprecated). We use the PPG
  factory images (`ppg/packer`, weekly, eu-central-1, tag `role=ppg-package-test`).
- SLES (PAYG): the name pattern skips the `sapcal`/`ecs` variants.
- AL2023: SSM `kernel-default` first, name pattern as fallback.

## Not verified yet

- The molecule AWS key may lack spot or `ssm:GetParameter` permissions. Both have fallbacks
  (on-demand, name pattern); check the first run's log.
- `jq`, `aws`, `unzip` on `docker-64gb`.
- OL arm64 and OL10 images exist in the factory but are not in the matrix.
