# AWS Graviton fallback for aarch64 RBE workers (PoC)

> Status: **PoC**. Code landed in `ondemand/scaler/` + `ondemand/scripts/`;
> feature is **disabled by default** (`aws.enabled: false`). Turning it on
> needs the AWS prerequisites in §3 and one run of
> `ondemand/scripts/setup-wireguard-hub.sh`.

## 1. Problem

aarch64 pools run on Hetzner `cax31` (Ampere Altra). Hetzner's ARM inventory
in `hel1`/`nbg1`/`fsn1` is frequently exhausted, so arm stages sit queued for
hours (see `ondemand/README.md` §11.1 — "aarch64 capacity is upstream of any
quota fix"). x86_64 (`cpx42`) does not have this problem.

The classic PSMDB Jenkins already solves the same problem for non-RBE builds
with an **EC2 Graviton fleet fallback when Hetzner CAX is unavailable**
(`percona-cd-platform/terraform/master-psmdb.tf` `module "psmdb_arm_fleet"`,
and `iam-gha-percona-server-ec2-fallback.tf`). This brings the same idea to
the BuildBarn RBE farm.

## 2. Architecture

AWS has effectively unlimited Graviton (`c7g`) capacity, and `c7g` is per-core
faster than `cax31` (so cold-cache aarch64 builds finish sooner, not just
"eventually"). The only hard problem is the network: an RBE worker speaks
**plaintext gRPC** to the central's *private* IP (`:8980` CAS/AC, `:8983`
scheduler) — deliberately bypassing the public, JWT-gated Envoy on `:8981`
("the network is the auth boundary"). An AWS worker isn't on Hetzner's private
network, so it reaches those ports over a **WireGuard tunnel**.

```
         AWS eu-central-1 (Graviton c7g, spot)              Hetzner hel1
   ┌─────────────────────────────────────────┐      ┌────────────────────────┐
   │ bb-worker (cloud-init)                   │      │ central bb-psmdb-ondemand
   │  wg0: 10.99.0.N/32 ──── WireGuard ───────┼─UDP──┼─▶ wg0 hub 10.99.0.1     │
   │  AllowedIPs = <central-priv-ip>/32       │ :51820│   (Floating IP)        │
   │  docker compose: bb-worker + runner      │      │   scheduler :8983 ◀─────┤
   │   dials <central-priv-ip>:8983/:8980 ────┼──────┼─▶ frontend  :8980  (priv)
   └─────────────────────────────────────────┘      └────────────────────────┘
```

**Two distinct arm64 fleets — don't conflate them.** This PoC is about the
*second* one:

1. **Jenkins agent node** — where the stage's `bazel build` is *launched*,
   where binaries are *linked* (`CppLink=local`), and from which the built
   packages are pushed to `repo.ci.percona.com`. In the PSMDB pipeline this is
   the `docker-aarch64` (Hetzner) / `docker-64gb-aarch64` (AWS) label, chosen
   by `params.CLOUD`. Already has an AWS path (ec2FleetCloud) — NOT managed by
   our scaler. This fleet is the only one that talks to repo.ci.
2. **BuildBarn RBE workers** — where the remote `CppCompile` actions execute.
   Spawned by *our* scaler; talk only to the central's CAS (`:8980`) and
   scheduler (`:8983`). These never touch repo.ci. **This** is the
   capacity-starved fleet the Graviton fallback addresses.

So the tunnel routes only the central's private IP — nothing else.

**The routing trick (why worker configs don't change):** the worker dials the
central's *Hetzner private IP* — byte-identical to a Hetzner worker. Its
WireGuard `AllowedIPs` routes that /32 through the tunnel; packets arrive on
the hub's `wg0` destined for the central's own local private IP and are
delivered locally; replies go back to the worker's `10.99.x` tunnel IP via
`wg0`. So `worker.jsonnet` / `common.libsonnet` and the central's `:8980/:8983`
port bindings are **untouched** — the only worker-side difference is a
WireGuard bring-up in cloud-init.

**Scaling policy — fallback/overflow, not co-equal.** AWS Graviton on-demand
is ~20× the hourly cost of `cax31`; spot ~70% cheaper but still pricier. So a
pool spawns on AWS **only after every Hetzner region in `region_try_chain` is
exhausted** for that spawn. `HetznerOps.create_worker` raises `RuntimeError`
exactly on region exhaustion; the scaler catches it and retries on AWS iff the
pool declares `aws_instance_type` and `aws.enabled` + the WireGuard hub are
configured.

**Instance selection — diversified Graviton spot pool.** A pool opts in with
`aws_fallback: true`; the shapes come from the global `aws.instance_types`
list (per-pool overridable). The default list is every 2xlarge across m/r
families and gen 6/7/8 (`m7g/m6g/m8g/m7gd/m6gd/r7g/r6g/r8g.2xlarge`) — all
**8 vCPU / ≥32 GB**, i.e. at least as good as Hetzner `cax31` (8c/16 GB) on
both CPU and RAM, with faster Neoverse cores. Because these are **spot**,
single-type pinning would invite high interruption + `no-capacity` rejections;
the scaler instead walks the list and moves to the next type on
`InsufficientInstanceCapacity` (the AWS analogue of Hetzner's `region_try_chain`),
so many distinct spot capacity pools back each spawn. Per-pool `max_nodes`
(5 on aarch64) caps the AWS workers too — they count toward the same pool/global
budgets as Hetzner workers.

**Peer lifecycle.** The scaler runs on the central (`network_mode: host` +
`cap_add: NET_ADMIN`) and owns peer state: on spawn it mints a per-worker
keypair, allocates a `10.99.0.0/16` tunnel IP, `wg set wg0 peer …`, and bakes
the private key + tunnel IP into the worker's cloud-init; on reap it removes
the peer. Tunnel IP + pubkey are persisted as EC2 tags so a scaler restart
rebuilds state; `reconcile_peers()` re-adds live workers and prunes orphans
each tick.

## 3. Prerequisites (from the AWS account / percona-cd-platform — IDs only)

WireGuard keeps the AWS footprint minimal: a worker needs only **outbound**
internet (to the hub's `:51820/udp` and Docker Hub). It does **not** need to
be in any particular VPC or peered network.

| Input | Where | Notes |
|---|---|---|
| Region | `eu-central-1` | ~20-30 ms to `hel1` (CAS-over-tunnel latency). `us-west-2` (existing arm fleet) is ~150 ms — avoid. |
| Subnet ID | **dedicated** subnet with egress | → `AWS_SUBNET_ID`. Must be separate infra (see billing note). |
| Security group(s) | egress-allowed; **no inbound** needed | → `AWS_SECURITY_GROUP_IDS` |
| AMI | Ubuntu arm64 (e.g. 24.04) in-region | resolve once from Canonical's SSM public param, pin → `AWS_AMI_ID` |
| IAM creds | narrow IAM user | RunInstances/TerminateInstances/DescribeInstances, region + instance-type + mandatory-tag scoped — mirror `iam-gha-percona-server-ec2-fallback.tf`. Scaler is on Hetzner ⇒ access key, no instance profile. → `AWS_ACCESS_KEY_ID` / `_SECRET` |
| Billing tag | `iit-billing-tag=psmdb-worker` + `PerconaKeep=True` | applied automatically. The billing tag isolates cost attribution AND satisfies percona-dev-admin reaper Lambdas (which kill untagged instances but spare tagged ones). |

**Billing isolation is a hard requirement:** the AWS resources (subnet/SG,
and ideally the VPC) must be dedicated to this fleet so cost does not land on
existing shared resources. `iit-billing-tag=psmdb-worker` is the attribution
key. Nothing in `percona-cd-platform` is modified — these are read as IDs.

## 4. Setup runbook

```bash
# 1) On the central: stand up the WireGuard hub (idempotent).
sudo WG_HUB_IP=10.99.0.1 ./ondemand/scripts/setup-wireguard-hub.sh
#    → prints WG_HUB_PUBKEY and the .env lines to set.

# 2) Open udp/51820 INBOUND on the central (Hetzner Cloud Firewall + host fw).

# 3) compose/.env on the central:
#      WG_HUB_PUBKEY=<from step 1>
#      WG_HUB_ENDPOINT=<floating-ip>:51820
#      WG_ALLOWED_IPS=<central-private-ip>/32     # or leave blank (defaulted)
#      AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…
#      AWS_AMI_ID=ami-… AWS_SUBNET_ID=subnet-… AWS_SECURITY_GROUP_IDS=sg-…

# 4) compose/config/ondemand-pools.yaml:
#      aws: { enabled: true, ... }
#      and aws_instance_type on the aarch64 pools that should fall back
#      (3 noble pools are pre-wired as the PoC example).

# 5) Roll the scaler. Keep SCALER_DRY_RUN=true for the first cycle.
docker compose up -d scaler && docker compose logs -f scaler
```

Expect on a Hetzner-exhausted aarch64 spawn:
`pool=…aarch64…: hetzner: all regions exhausted … — falling back to AWS Graviton`
then (dry-run off) `aws: spawned bb-worker-… (id=i-…) in eu-central-1`.

## 5. Files

| File | Change |
|---|---|
| `ondemand/scaler/providers.py` | **new** — `CloudProvider` interface, `HetznerOps` (moved), `AwsOps` (boto3), shared `ManagedVM` + label/tag conventions |
| `ondemand/scaler/wireguard.py` | **new** — keypair gen, hub peer add/remove, tunnel-IP allocation, reconcile |
| `ondemand/scaler/scaler.py` | provider registry, multi-provider VM view, Hetzner→AWS fallback, wg peer lifecycle, AWS/WireGuard config |
| `ondemand/scaler/bootstrap.py` | **+`render_aws_user_data`** — wg-enabled cloud-init (gzip-shipped to fit EC2's 16 KB) |
| `ondemand/scaler/{Dockerfile,requirements.txt}` | `wireguard-tools`, `boto3` |
| `ondemand/compose/docker-compose.yml` | scaler `cap_add: NET_ADMIN` + AWS/WG env |
| `ondemand/compose/.env.example` | AWS + WireGuard vars |
| `ondemand/compose/config/ondemand-pools.yaml` | `aws:` (incl. diversified `instance_types`) / `wireguard:` blocks; `aws_fallback: true` on 3 noble aarch64 pools |
| `ondemand/aws-fallback-vpc/` | **new** — standalone Terraform for the dedicated, billing-isolated eu-central-1 VPC (checked by `create-central.sh`) |
| `ondemand/scripts/setup-wireguard-hub.sh` | **new** — stand up the hub on the central |

## 6. Spot, CAS egress, and what's actually a risk

**Spot is the intended mode (`use_spot: true`), and reclaim is safe.** RBE is
built for worker churn:

- The Bazel *client* (the Jenkins agent) submits actions to the scheduler; the
  scheduler dispatches each to a worker. If a spot worker is reclaimed, its
  WireGuard tunnel + scheduler gRPC stream drop, the scheduler notices the
  disconnect and **re-queues that worker's in-flight actions**. The client
  just sees those actions take longer (absorbed by Bazel's default 3600s
  `--remote_timeout`); the build does NOT fail.
- The scaler, seeing renewed queue pressure, spawns a replacement (Hetzner
  first, AWS fallback) which picks up the re-queued actions — exactly the
  "new instance comes up and grabs the chunks" behaviour you expect.
- **Only the actions mid-execution on the reclaimed worker are redone.**
  Everything that already finished was uploaded to the central's CAS, so those
  results persist and are not recomputed. So a reclaim costs at most one
  worker's in-flight slice, never the whole build.
- AWS gives a 2-minute spot interruption notice. We don't act on it today
  (scheduler re-queue already keeps things correct); a future graceful-drain
  on the notice would shave the re-queue latency. Not needed for the PoC.

**CAS egress — the cost to watch (not a correctness risk).** A remote compile
action downloads its inputs from the central's CAS (central→AWS = AWS ingress,
free) and uploads its `.o`/action-result back (AWS→central = AWS egress,
~$0.09/GB). Cold-cache aarch64 builds move several GB, so the AWS egress bill
scales with cold-build volume. Fallback-only policy bounds it (AWS runs only
when Hetzner is dry); `eu-central-1`↔`hel1` keeps latency low. Watch the bill;
warm builds (mostly cache hits) move far less.

**Resolved / non-issues:**

- ~~repo.ci.percona.com~~ — RBE workers don't reach it (that's the Jenkins
  agent). Tunnel routes only the central's private IP. No `ip_forward`/NAT.
- ~~Central CPU/RAM as the hub~~ — measured on the live central: 3.5 GB / 30.6 GB
  RAM, load ~0.15, 16 cores idle. WireGuard is in-kernel and cheap; ample
  headroom. (The old ~93% figure was a smaller pre-`cpx62` box.)

**Minor, revisit later:**

- **User-data secret.** The worker's wg private key rides in EC2 user-data
  (readable via IMDS on the instance itself). Acceptable for ephemeral PoC
  workers; if it ever matters, fetch the key from SSM Parameter Store at boot
  instead.

## 7. Follow-ups

- Generalise to a `(provider, server_type, region)` round-robin (the
  `README.md` "follow-ups still open" note) so a stuck `cax31` order can also
  fall to `cax41` before going to AWS.
- Replicate `aws_instance_type` onto the remaining aarch64 pools (all distros)
  once the noble PoC is proven.
- Optional: snapshot/AMI with Docker + WireGuard pre-baked to cut AWS cold-boot
  from ~2 min toward ~40 s (mirrors the Hetzner snapshot follow-up).
