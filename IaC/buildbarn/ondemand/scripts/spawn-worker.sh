#!/usr/bin/env bash
#
# spawn-worker.sh — bring up a single ondemand bb-worker VM that joins the
# central bb-psmdb-ondemand scheduler.
#
# Phase 1 goal: produce ONE worker for ONE (pool, psmdb_version) combination,
# fully manual, with a public IP attached so the operator can SSH in and poke
# around. Later phases will:
#   * remove the public IP (workers reach ghcr.io via the central's NAT or a
#     Hetzner egress; or we accept that anonymous ghcr pulls need an outbound
#     IPv4 — we'll cross that bridge when we get there)
#   * be invoked programmatically by the scaler daemon watching the
#     BuildQueueState gRPC stream from the central.
#
# What this script does:
#
#   1. Preflight checks on the operator's laptop.
#   2. Discover central's public + private IPs and browser URL via hcloud.
#   3. Render cloud-init.yml.tmpl (only __WORKER_HOSTNAME__ placeholder).
#   4. `hcloud server create` with cloud-init user-data. Attach both SSH keys
#      and the psmdb.cd private network.
#   5. Wait for SSH, then for cloud-init to finish (`cloud-init status --wait`).
#   6. Render the compose stack + worker jsonnets locally (sed the central's
#      private IP, public URL, pool name, worker hostname, runner image into
#      copies of worker/*) and rsync them into /opt/buildbarn on the VM.
#   7. ssh in, `docker compose pull && docker compose up -d`.
#   8. Verify the worker registered on the central by scraping the scheduler
#      admin UI for its hostname.
#   9. Print a summary with ssh command, docker logs cheat-sheet, and the
#      hcloud command to destroy the VM when done.
#
# Usage:
#   POOL=ubuntu-noble-x86_64__v8_3__9873907c9659 ./scripts/spawn-worker.sh
#
#   POOL must be a YAML key that exists in
#   IaC/buildbarn/ondemand/compose/config/ondemand-pools.yaml.
#   Naming convention is documented in that file's header — short form
#   `<runner-image-basename>__v<version>__<short-sha>`, e.g.
#   `oraclelinux-8-x86_64__v8_0__9873907c9659`.
#
# The script is NOT idempotent against a duplicate name. If you rerun with
# the same SERVER_NAME, it will complain; each spawn gets a unique timestamp
# suffix by default. Delete the VM before re-running if you need to recycle.

set -euo pipefail

# -----------------------------------------------------------------------------
# Required inputs.
# -----------------------------------------------------------------------------
: "${POOL:?set POOL (must match a key in ondemand-pools.yaml — see header)}"

# -----------------------------------------------------------------------------
# Optional inputs — defaults chosen for first-test conditions.
# -----------------------------------------------------------------------------
: "${SERVER_TYPE:=cpx42}"   # 8c shared x86 / 16 GB / 320 GB — same family as the central; cpx41 (older line) is not offered in hel1
: "${LOCATION:=hel1}"
: "${OS_IMAGE:=debian-13}"
: "${CENTRAL_NAME:=bb-psmdb-ondemand}"
: "${NETWORK_ID:=11374636}"               # psmdb.cd.percona.com
: "${SSH_KEY_IDS:=24333399 111196538}"    # htz.cd.key + htz.cd.bb-psmdb-ondemand
: "${SSH_PRIV_KEY:=$HOME/.ssh/htz.cd.bb-psmdb-ondemand.key}"

# -----------------------------------------------------------------------------
# Resolve pool config from ondemand-pools.yaml.
# -----------------------------------------------------------------------------
# The YAML is the single source of truth for routing keys. We read three
# fields here:
#   * runner_image        → docker pull URL (immutable :<version>-<sha> tag)
#   * bazel_pool_value    → architecture label (x86_64 / aarch64)
#   * psmdb_version       → informational; used for the Hetzner label
#                            psmdb.version=<value> so ops can filter VMs
#                            by release line.
# The full container-image routing key is derived as `docker://${runner_image}`
# (matches PSMDB fork's psmdb_rbe_containers.bzl emission contract).
: "${POOLS_YAML:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/compose/config/ondemand-pools.yaml}"
_pool_props=$(POOL="$POOL" POOLS_YAML="$POOLS_YAML" python3 - <<'PY'
import os, sys
try:
    import yaml
except ImportError:
    sys.exit("python3-yaml is required on the operator laptop (apt: python3-yaml, brew: python + pip install pyyaml)")
pool = os.environ["POOL"]
path = os.environ["POOLS_YAML"]
with open(path) as f:
    data = yaml.safe_load(f)
pc = (data.get("pools") or {}).get(pool)
if not pc:
    sys.exit(f"pool '{pool}' not in {path}")
ri = pc.get("runner_image") or ""
bp = pc.get("bazel_pool_value") or ""
pv = pc.get("psmdb_version") or ""
if not ri:
    sys.exit(f"pool '{pool}' has empty runner_image in {path}")
if not bp:
    sys.exit(f"pool '{pool}' has empty bazel_pool_value in {path}")
print(f"{ri}\t{bp}\t{pv}")
PY
)
# Bash command-substitution failure does NOT propagate through errexit in
# the absence of `shopt -s inherit_errexit`. Validate the resolution
# explicitly so a typo in $POOL or a missing runner_image doesn't silently
# yield empty placeholders downstream.
[[ -n "$_pool_props" ]] \
  || { echo "  ✗ failed to resolve pool '$POOL' from $POOLS_YAML — re-run with python errors visible" >&2; exit 1; }
RUNNER_IMAGE=${_pool_props%%$'\t'*}
_rest=${_pool_props#*$'\t'}
BAZEL_POOL_VALUE=${_rest%%$'\t'*}
PSMDB_VERSION=${_rest#*$'\t'}
[[ -n "$RUNNER_IMAGE" && -n "$BAZEL_POOL_VALUE" && -n "$PSMDB_VERSION" ]] \
  || { echo "  ✗ pool '$POOL' resolved with empty fields: runner_image='$RUNNER_IMAGE' bazel_pool_value='$BAZEL_POOL_VALUE' psmdb_version='$PSMDB_VERSION'" >&2; exit 1; }
# `docker://` prefix is what Bazel sends, what the scheduler stores in its
# predeclared queue, and what the worker must register with. ALL THREE must
# agree byte-for-byte.
CONTAINER_IMAGE="docker://${RUNNER_IMAGE}"

# Unique-ish server name. Hetzner validates this as an RFC 1123 hostname:
# lowercase letters/digits/hyphens only (NO underscores, NO uppercase) AND
# total length ≤ 63 chars. Our YAML pool keys can be up to ~46 chars
# (e.g. `amazonlinux-2023-x86_64__vmaster__9873907c9659`) and double `__`
# gets converted to `--` which some validators reject — so we (a) lowercase
# + replace `_` with `-`, (b) collapse runs of consecutive hyphens to one,
# (c) bound the slug so the full name stays ≤ 63 chars after we glue the
# `bb-worker-` prefix (10 chars) and `-<TS>` suffix (16 chars: 26 total
# overhead, leaving 37 chars for the slug). The full pool key is preserved
# losslessly in the `pool=<POOL>` Hetzner label below — server name is
# only for human-readable VM identification.
: "${TS:=$(date -u +%Y%m%d-%H%M%S)}"
POOL_SLUG=$(printf '%s' "$POOL" | tr '_[:upper:]' '-[:lower:]' | tr -s '-')
POOL_SLUG=${POOL_SLUG:0:37}
POOL_SLUG=${POOL_SLUG%-}              # strip trailing hyphen left by truncate
: "${SERVER_NAME:=bb-worker-${POOL_SLUG}-${TS}}"
: "${WORKER_HOSTNAME:=$SERVER_NAME}"

# -----------------------------------------------------------------------------
# Repo paths.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONDEMAND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKER_SRC="$ONDEMAND_DIR/worker"
CLOUD_INIT_TMPL="$WORKER_SRC/cloud-init.yml.tmpl"

REMOTE_BASE=/opt/buildbarn

# Staging dir on the operator's laptop. Rendered copies of worker/* live here
# with all placeholders resolved, then get rsync'd to the VM.
STAGE_DIR=$(mktemp -d -t bb-worker-stage.XXXXXX)
trap 'rm -rf "$STAGE_DIR"' EXIT

# -----------------------------------------------------------------------------
# Pretty logging — same palette as create-central.sh so scrollbacks read as
# one conversation.
# -----------------------------------------------------------------------------
log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;35m=== %s ===\033[0m\n' "$*"; }

# -----------------------------------------------------------------------------
# Preflight.
# -----------------------------------------------------------------------------
preflight() {
  step "Preflight"

  for bin in hcloud jq rsync ssh sed; do
    command -v "$bin" >/dev/null || die "missing required binary: $bin"
  done
  ok "local binaries present"

  hcloud server-type list -o noheader >/dev/null 2>&1 \
    || die "hcloud not authenticated — export HCLOUD_TOKEN or run 'hcloud context create'"
  ok "hcloud authenticated"

  [[ -r "$SSH_PRIV_KEY" ]] || die "cannot read SSH private key: $SSH_PRIV_KEY"
  ok "SSH key readable ($SSH_PRIV_KEY)"

  [[ -d "$WORKER_SRC" ]]               || die "worker source missing: $WORKER_SRC"
  [[ -f "$WORKER_SRC/docker-compose.yml" ]] \
                                       || die "worker/docker-compose.yml missing"
  [[ -d "$WORKER_SRC/config" ]]        || die "worker/config missing"
  [[ -f "$CLOUD_INIT_TMPL" ]]          || die "cloud-init template missing: $CLOUD_INIT_TMPL"
  ok "repo layout OK"

  # Validate that no existing server collides with our name. If the operator
  # rerun the script too fast the timestamp might actually collide — be loud.
  if hcloud server describe "$SERVER_NAME" -o json >/dev/null 2>&1; then
    die "server '$SERVER_NAME' already exists. Delete it first or pick a unique SERVER_NAME."
  fi
  ok "server name free: $SERVER_NAME"

  # Central must be up — worker blobstore/scheduler both live on it, so no
  # point in creating a worker if the control plane is offline.
  CENTRAL_JSON=$(hcloud server describe "$CENTRAL_NAME" -o json 2>/dev/null) \
    || die "central server '$CENTRAL_NAME' not found — run create-central.sh first"
  CENTRAL_PUBLIC_IP=$(jq -r '.public_net.ipv4.ip // empty' <<<"$CENTRAL_JSON")
  CENTRAL_PRIVATE_IP=$(jq -r '.private_net[0].ip // empty' <<<"$CENTRAL_JSON")
  [[ -n "$CENTRAL_PUBLIC_IP"  ]] || die "central has no public IPv4"
  [[ -n "$CENTRAL_PRIVATE_IP" ]] || die "central has no private IP on network $NETWORK_ID"
  ok "central at public=$CENTRAL_PUBLIC_IP private=$CENTRAL_PRIVATE_IP"

  CENTRAL_PUBLIC_URL="http://${CENTRAL_PUBLIC_IP}:7984"
}

# -----------------------------------------------------------------------------
# Render the cloud-init user-data and the full compose stack to $STAGE_DIR.
# Nothing touches the real filesystem or Hetzner — this is a dry run for
# the rendering. If something's wrong with the template, we'd rather notice
# now than after paying for a cpx42 minute.
# -----------------------------------------------------------------------------
render() {
  step "Render configs"

  # 1) cloud-init.
  sed -e "s|__WORKER_HOSTNAME__|$WORKER_HOSTNAME|g" \
      "$CLOUD_INIT_TMPL" > "$STAGE_DIR/cloud-init.yml"
  ok "cloud-init rendered → $STAGE_DIR/cloud-init.yml"

  # 2) Worker compose stack. Copy tree then sed placeholders in place.
  mkdir -p "$STAGE_DIR/worker/config"
  cp "$WORKER_SRC/docker-compose.yml" "$STAGE_DIR/worker/"
  cp "$WORKER_SRC/config/"*.jsonnet "$STAGE_DIR/worker/config/"
  cp "$WORKER_SRC/config/"*.libsonnet "$STAGE_DIR/worker/config/"

  # docker-compose.yml: runner image only.
  sed -i.bak \
    -e "s|__RUNNER_IMAGE__|$RUNNER_IMAGE|g" \
    "$STAGE_DIR/worker/docker-compose.yml"

  # common.libsonnet: central's private IP (blobstore) + public URL (browser).
  sed -i.bak \
    -e "s|__CENTRAL_PRIVATE_IP__|$CENTRAL_PRIVATE_IP|g" \
    -e "s|__CENTRAL_PUBLIC_URL__|$CENTRAL_PUBLIC_URL|g" \
    "$STAGE_DIR/worker/config/common.libsonnet"

  # worker.jsonnet: scheduler address + workerId metadata + platform tuple
  # (Pool + full container-image URL). Platform tuple must be in lockstep
  # with scaler/bootstrap.py:render_user_data(); see worker.jsonnet header.
  # The `|` sed delimiter is deliberate — CONTAINER_IMAGE contains `/` and
  # `:`, which would clash with the default `s/.../...` form.
  sed -i.bak \
    -e "s|__CENTRAL_PRIVATE_IP__|$CENTRAL_PRIVATE_IP|g" \
    -e "s|__POOL_NAME__|$POOL|g" \
    -e "s|__WORKER_HOSTNAME__|$WORKER_HOSTNAME|g" \
    -e "s|__BAZEL_POOL_VALUE__|$BAZEL_POOL_VALUE|g" \
    -e "s|__CONTAINER_IMAGE__|$CONTAINER_IMAGE|g" \
    "$STAGE_DIR/worker/config/worker.jsonnet"

  # Clean up BSD-sed leftovers (GNU sed would skip these, BSD sed always
  # writes them; either way we don't want .bak in the rsync target).
  find "$STAGE_DIR/worker" -name '*.bak' -delete

  # Sanity: no placeholders should remain in the rendered tree. If any do,
  # the template has a typo and we'd silently ship broken configs.
  if grep -rEl '__[A-Z_]+__' "$STAGE_DIR/worker" >/dev/null 2>&1; then
    warn "unresolved placeholders remain:"
    # NB: -E is required on BSD grep (macOS) for the `+` quantifier — without
    # it the second grep would silently match nothing and we'd die without
    # ever telling the operator which file is broken.
    grep -rEn '__[A-Z_]+__' "$STAGE_DIR/worker" >&2
    die "fix the sed invocations in render() before proceeding"
  fi
  ok "worker/ rendered with: RUNNER=$RUNNER_IMAGE"
  ok "                       CENTRAL_PRIVATE=$CENTRAL_PRIVATE_IP"
  ok "                       CENTRAL_PUBLIC=$CENTRAL_PUBLIC_URL"
}

# -----------------------------------------------------------------------------
# Create the Hetzner VM and attach it to the private network.
# -----------------------------------------------------------------------------
PUBLIC_IP=""
PRIVATE_IP=""

create_server() {
  step "Server"

  local ssh_args=""
  for key_id in $SSH_KEY_IDS; do
    ssh_args="$ssh_args --ssh-key $key_id"
  done

  log "hcloud server create $SERVER_NAME ($SERVER_TYPE, $OS_IMAGE, $LOCATION) …"
  # shellcheck disable=SC2086
  hcloud server create \
    --name "$SERVER_NAME" \
    --type "$SERVER_TYPE" \
    --image "$OS_IMAGE" \
    --location "$LOCATION" \
    --network "$NETWORK_ID" \
    $ssh_args \
    --user-data-from-file "$STAGE_DIR/cloud-init.yml" \
    --label role=bb-worker \
    --label project=psmdb-buildbarn \
    --label pool="$POOL" \
    --label psmdb-version="$PSMDB_VERSION" \
    --label spawned-by="$(whoami 2>/dev/null || echo unknown)"
  ok "server created"

  local srv_json
  srv_json=$(hcloud server describe "$SERVER_NAME" -o json)
  PUBLIC_IP=$(jq -r '.public_net.ipv4.ip'        <<<"$srv_json")
  PRIVATE_IP=$(jq -r '.private_net[0].ip // empty' <<<"$srv_json")
  [[ -n "$PUBLIC_IP"  && "$PUBLIC_IP"  != "null" ]] || die "could not read public IP"
  [[ -n "$PRIVATE_IP" && "$PRIVATE_IP" != "null" ]] || die "could not read private IP"
  ok "public IP:  $PUBLIC_IP"
  ok "private IP: $PRIVATE_IP"
}

# -----------------------------------------------------------------------------
# Wait for SSH, then wait for cloud-init to finish. We care about the latter
# because cloud-init is what installs docker — compose commands would fail if
# we hit the VM before it's done.
#
# SSH options note: ondemand workers are throwaway VMs and Hetzner aggressively
# recycles public IPv4s. Recording host keys in ~/.ssh/known_hosts would mean
# every spawn-after-delete with a recycled IP would silently hang here on a
# host-key-changed mismatch (StrictHostKeyChecking=accept-new only accepts
# *new* hosts, not changed ones). Sending host keys to /dev/null with
# StrictHostKeyChecking=no removes that whole class of failure for what is
# correctly an ephemeral, untrusted-by-design host. The same options are
# reused for rsync below so they stay in sync.
# -----------------------------------------------------------------------------
SSH_OPTS="-i $SSH_PRIV_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

wait_for_ssh() {
  step "SSH reachability"

  log "waiting for $PUBLIC_IP:22 …"
  for _ in {1..90}; do
    # shellcheck disable=SC2086  # word-splitting on SSH_OPTS is intentional
    if ssh $SSH_OPTS \
           -o BatchMode=yes \
           -o ConnectTimeout=5 \
           "root@$PUBLIC_IP" true 2>/dev/null; then
      ok "SSH ready"
      return
    fi
    sleep 3
  done
  die "SSH didn't come up within ~4.5 minutes"
}

rssh()        { ssh $SSH_OPTS "root@$PUBLIC_IP" "$@"; }
central_ssh() { ssh $SSH_OPTS "root@$CENTRAL_PUBLIC_IP" "$@"; }
rrsync()      { rsync -a --delete -e "ssh $SSH_OPTS" "$@"; }

wait_for_cloud_init() {
  step "cloud-init"

  log "waiting for cloud-init to finish (may take 2–4 minutes on first boot) …"
  if rssh 'cloud-init status --wait' >/dev/null 2>&1; then
    ok "cloud-init finished"
  else
    warn "cloud-init exited non-zero; dumping the tail of /var/log/cloud-init-output.log for diagnosis:"
    rssh 'tail -n 80 /var/log/cloud-init-output.log' || true
    die "cloud-init failed — fix the template or investigate the VM (ssh -i $SSH_PRIV_KEY root@$PUBLIC_IP)"
  fi

  # Sanity check: docker must actually be on PATH now.
  rssh 'docker --version && docker compose version' \
    || die "cloud-init finished but docker isn't available — inspect /var/log/cloud-init-output.log"
  ok "docker present on worker"
}

# -----------------------------------------------------------------------------
# Push the rendered compose stack and bring services up.
# -----------------------------------------------------------------------------
deploy_stack() {
  step "Deploy bb-worker stack"

  rssh "mkdir -p $REMOTE_BASE"

  log "rsync worker/ → $REMOTE_BASE"
  rrsync "$STAGE_DIR/worker/" "root@$PUBLIC_IP:$REMOTE_BASE/"
  ok "files pushed"

  # bb-worker won't auto-create its buildDirectoryPath / cacheDirectoryPath,
  # and runner-installer won't create /bb either — both need to exist before
  # the bind mounts go up. Same pattern as storage's persistent_state in
  # create-central.sh.
  rssh "REMOTE_BASE=$REMOTE_BASE bash -se" <<'REMOTE'
set -euo pipefail
mkdir -p "$REMOTE_BASE/volumes/worker/build" \
         "$REMOTE_BASE/volumes/worker/cache" \
         "$REMOTE_BASE/volumes/bb"
REMOTE
  ok "state dirs in place"

  rssh "REMOTE_BASE=$REMOTE_BASE bash -se" <<'REMOTE'
set -euo pipefail
cd "$REMOTE_BASE"

# Anonymous ghcr.io pull — if the package visibility ever changes to private,
# this is where the pull will fail. Add `docker login ghcr.io -u <user> -p <token>`
# here and provision the token via cloud-init's write_files.
docker compose pull

docker compose up -d

echo
echo "  === docker compose ps ==="
docker compose ps
REMOTE
  ok "stack up"
}

# -----------------------------------------------------------------------------
# Confirm the worker registered.
#
# The authoritative source of truth is the scheduler's
# BuildQueueState/ListPlatformQueues gRPC: it reports `workersCount` against
# the queue keyed by our exact `container-image` routing key. Once it goes to
# >= 1, the worker is registered, plain and simple.
#
# Earlier versions of this function tried to scrape the scheduler admin HTML
# page (`curl :7982 | grep 'Pool="x86_64"'`). That was unreliable because
# the page HTML-encodes the quotes (`Pool=&#34;x86_64&#34;`) and because as
# soon as we have predeclared queues, every queue contains `Pool="x86_64"`,
# so the marker was either always-true or always-false depending on URL
# encoding. The gRPC path is exact and matches one queue only — the one
# we're actually trying to fill.
#
# The worker-side "no Fatal error in the last 15 s" probe was also dropped:
# the bb-worker image is distroless and defaults to logging only WARN+, so
# `docker logs` is permanently empty in healthy operation. That made the
# probe a useless (and misleading) tautology.
# -----------------------------------------------------------------------------

verify_registered() {
  step "Verify registration"

  log "waiting up to ~3 min for worker '$WORKER_HOSTNAME' to register against \
queue container-image=$CONTAINER_IMAGE …"

  local i workers_count=0 last_state="(not yet checked)"
  for i in {1..36}; do
    sleep 5
    [[ $((i % 6)) -eq 0 ]] && log "  still waiting ($((i * 5)) s elapsed; $last_state) …"

    # Pull the full BuildQueueState JSON over SSH→docker-exec to the central's
    # `scaler` container (which already has grpcurl bundled and is on the
    # right Docker network for localhost:8984). Filter locally with jq so we
    # don't have to escape it through ssh quotes.
    local queue_json
    queue_json=$(central_ssh \
      "cd /var/lib/buildbarn/compose && docker compose exec -T scaler \
       grpcurl -plaintext localhost:8984 \
         buildbarn.buildqueuestate.BuildQueueState/ListPlatformQueues \
       2>/dev/null" || true)

    if [[ -z "$queue_json" ]]; then
      last_state="scheduler unreachable"
      continue
    fi

    # Sum workersCount across every sizeClassQueue of every platformQueue
    # whose `container-image` property matches our routing key exactly.
    # `// 0` keeps jq happy when the field is absent on cold queues.
    workers_count=$(printf '%s' "$queue_json" \
      | jq -r --arg img "$CONTAINER_IMAGE" '
          [ .platformQueues[]
            | select(.name.platform.properties[]?
                | select(.name == "container-image") | .value == $img)
            | .sizeClassQueues[]?.workersCount // 0
          ] | add // 0' 2>/dev/null \
      || echo 0)

    last_state="workers=$workers_count"

    if [[ "${workers_count:-0}" =~ ^[0-9]+$ ]] && (( workers_count >= 1 )); then
      ok "worker is registered ($workers_count slot(s) on the scheduler)"
      ok "scheduler admin: http://$CENTRAL_PUBLIC_IP:7982/"
      return
    fi
  done

  warn "worker did NOT show up in scheduler queue after ~3 min ($last_state)."
  warn "The VM is up — investigate with:"
  warn "  ssh -i $SSH_PRIV_KEY root@$PUBLIC_IP 'cd $REMOTE_BASE && docker compose logs --tail=100 worker runner'"
  warn "  ssh -i $SSH_PRIV_KEY root@$CENTRAL_PUBLIC_IP \\"
  warn "    'cd /var/lib/buildbarn/compose && docker compose exec -T scaler \\"
  warn "       grpcurl -plaintext localhost:8984 \\"
  warn "         buildbarn.buildqueuestate.BuildQueueState/ListPlatformQueues' | \\"
  warn "    jq '.platformQueues[] | select(.sizeClassQueues[]?.workersCount // 0 > 0)'"
}

# -----------------------------------------------------------------------------
# Summary.
# -----------------------------------------------------------------------------
summary() {
  cat <<EOF

\033[1;32mbb-worker spawned.\033[0m

  Name              : $SERVER_NAME
  Type / location   : $SERVER_TYPE / $LOCATION ($OS_IMAGE)
  Pool              : $POOL   (PSMDB $PSMDB_VERSION)
  Bazel Pool value  : $BAZEL_POOL_VALUE
  Routing key       : $CONTAINER_IMAGE
  Runner image      : $RUNNER_IMAGE
  Public IP         : $PUBLIC_IP
  Private IP        : $PRIVATE_IP
  Central private   : $CENTRAL_PRIVATE_IP
  Worker hostname   : $WORKER_HOSTNAME   (used as workerId on the scheduler)

  SSH for debug     : ssh -i $SSH_PRIV_KEY root@$PUBLIC_IP
  Inspect stack     : cd $REMOTE_BASE && docker compose ps && docker compose logs -f
  Scheduler admin   : http://$CENTRAL_PUBLIC_IP:7982/
  bb-browser        : http://$CENTRAL_PUBLIC_IP:7984/

  Next:
    * From the operator's laptop, run Bazel against the central:
        bazel build --remote_executor=grpc://$CENTRAL_PUBLIC_IP:8981 \\
                    --remote_instance_name=hardlinking ...
    * When finished, destroy the VM:
        hcloud server delete $SERVER_NAME
EOF
}

# -----------------------------------------------------------------------------
# Main.
# -----------------------------------------------------------------------------
main() {
  preflight
  render
  create_server
  wait_for_ssh
  wait_for_cloud_init
  deploy_stack
  verify_registered
  summary
}

main "$@"
