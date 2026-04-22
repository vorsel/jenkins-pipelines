#!/usr/bin/env bash
#
# create-central.sh — bring up (or adopt) the bb-psmdb-ondemand central node.
#
# What this script does, in order:
#
#   1. Preflight checks on the operator's laptop (hcloud auth, jq, rsync,
#      local SSH private key, repo layout, Hetzner resource IDs).
#   2. Ensure the server exists in Hetzner Cloud (create if missing) with
#      both SSH keys installed, attached to the private network 11374636,
#      on Debian 13.
#   3. Attach the 750 GB xfs volume (ID 105484418) if not already attached.
#   4. Install Docker on the host (via get.docker.com) and rsync, if missing.
#   5. Mount the volume at /var/lib/buildbarn and add an fstab entry.
#   6. Detect volume state:
#        * empty/fresh     → bootstrap from scratch
#        * already populated → interactive prompt:
#              attach      (keep CAS data; refresh configs only)
#              wipe-attach (mkfs.xfs + bootstrap from scratch — DESTROYS CAS)
#              abort       (exit; operator can SSH in manually)
#   7. Rsync ../compose/ and the shared ../../reapi-proxy/ into /var/lib/buildbarn/.
#   8. Write .env with the server's private IP, sed-replace the browserUrl
#      placeholder with the public IP.
#   9. `docker compose build reapi-proxy && docker compose pull && docker compose up -d`
#  10. Smoke-test ports and print a summary.
#
# The script is idempotent — re-running it after a successful bootstrap should
# be a no-op (unless the volume is already populated, in which case you'll get
# the attach/wipe-attach/abort prompt, because there's no safe default).
#
# Set MODE=attach|wipe-attach|abort to skip the interactive prompt. Useful for
# CI / scripted recoveries.

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration — override via env if you're deploying a variant (e.g. staging).
# -----------------------------------------------------------------------------
: "${SERVER_NAME:=bb-psmdb-ondemand}"
: "${SERVER_TYPE:=cpx42}"
: "${LOCATION:=hel1}"
: "${OS_IMAGE:=debian-13}"

# Hetzner resource IDs. These are PSMDB-project-specific and hard-coded here
# because there's exactly one volume and one private network we care about.
: "${VOLUME_ID:=105484418}"                   # psmdb-buildbarn-cas-ondemand
: "${NETWORK_ID:=11374636}"                   # psmdb.cd.percona.com
: "${SSH_KEY_IDS:=24333399 111196538}"        # htz.cd.key + htz.cd.bb-psmdb-ondemand

# The operator's SSH private key used to reach the new server. Matches
# SSH key ID 111196538 uploaded to Hetzner.
: "${SSH_PRIV_KEY:=$HOME/.ssh/htz.cd.bb-psmdb-ondemand.key}"

# Mode override (attach|wipe-attach|abort). Empty = ask interactively.
: "${MODE:=}"

# -----------------------------------------------------------------------------
# Repo paths (resolved relative to this script so the tool can be invoked from
# any CWD).
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONDEMAND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_SRC="$ONDEMAND_DIR/compose"
REAPI_PROXY_SRC="$(cd "$ONDEMAND_DIR/../reapi-proxy" && pwd)"

# Remote paths on the central host.
REMOTE_BASE=/var/lib/buildbarn
REMOTE_COMPOSE="$REMOTE_BASE/compose"
REMOTE_REAPI="$REMOTE_BASE/reapi-proxy"
VOLUME_DEV="/dev/disk/by-id/scsi-0HC_Volume_${VOLUME_ID}"

# -----------------------------------------------------------------------------
# Pretty logging.
# -----------------------------------------------------------------------------
log()   { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m  ! %s\033[0m\n' "$*"; }
die()   { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }
step()  { printf '\n\033[1;35m=== %s ===\033[0m\n' "$*"; }

# -----------------------------------------------------------------------------
# Preflight.
# -----------------------------------------------------------------------------
preflight() {
  step "Preflight"

  for bin in hcloud jq rsync ssh ssh-keyscan; do
    command -v "$bin" >/dev/null || die "missing required binary: $bin"
  done
  ok "local binaries present"

  # Fail fast if hcloud isn't authenticated — avoids cryptic errors later.
  hcloud server-type list -o noheader >/dev/null 2>&1 \
    || die "hcloud not authenticated — export HCLOUD_TOKEN or run 'hcloud context create'"
  ok "hcloud authenticated"

  [[ -r "$SSH_PRIV_KEY" ]] || die "cannot read SSH private key: $SSH_PRIV_KEY"
  ok "SSH key readable ($SSH_PRIV_KEY)"

  [[ -d "$COMPOSE_SRC" ]]      || die "compose source missing: $COMPOSE_SRC"
  [[ -f "$COMPOSE_SRC/docker-compose.yml" ]] \
    || die "compose/docker-compose.yml missing"
  [[ -d "$COMPOSE_SRC/config" ]] \
    || die "compose/config missing"
  [[ -d "$REAPI_PROXY_SRC" ]]  || die "reapi-proxy source missing: $REAPI_PROXY_SRC"
  [[ -f "$REAPI_PROXY_SRC/Dockerfile" ]] \
    || die "reapi-proxy/Dockerfile missing"
  ok "repo layout OK"

  for key_id in $SSH_KEY_IDS; do
    hcloud ssh-key describe "$key_id" >/dev/null 2>&1 \
      || die "Hetzner SSH key $key_id not found in project"
  done
  ok "Hetzner SSH keys present: $SSH_KEY_IDS"

  hcloud network describe "$NETWORK_ID" >/dev/null 2>&1 \
    || die "Hetzner network $NETWORK_ID not found"
  ok "Hetzner private network $NETWORK_ID present"

  # Volume must exist and be xfs-formatted. hcloud doesn't tell us the fs
  # directly in `describe`, but it does tell us the format if we created it
  # with --format xfs. If someone created it manually without --format, we'll
  # detect on the remote host during the mount step and fail cleanly there.
  local vol_json
  vol_json=$(hcloud volume describe "$VOLUME_ID" -o json 2>/dev/null) \
    || die "Hetzner volume $VOLUME_ID not found"
  local vol_size vol_location vol_server
  vol_size=$(jq -r '.size' <<<"$vol_json")
  vol_location=$(jq -r '.location.name' <<<"$vol_json")
  vol_server=$(jq -r '.server // empty' <<<"$vol_json")
  [[ "$vol_location" == "$LOCATION" ]] \
    || die "volume is in $vol_location but server will be in $LOCATION"
  ok "volume ${VOLUME_ID} (${vol_size} GB, ${vol_location}) present"
  if [[ -n "$vol_server" && "$vol_server" != "null" ]]; then
    local attached_to
    attached_to=$(hcloud server describe "$vol_server" -o json \
                  | jq -r '.name // empty')
    if [[ "$attached_to" == "$SERVER_NAME" ]]; then
      ok "volume already attached to $SERVER_NAME"
    else
      die "volume is attached to a different server ($attached_to) — detach manually before proceeding"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Ensure the server exists; create it if not. Populate PUBLIC_IP / PRIVATE_IP.
# -----------------------------------------------------------------------------
PUBLIC_IP=""
PRIVATE_IP=""

ensure_server() {
  step "Server"

  if hcloud server describe "$SERVER_NAME" -o json >/dev/null 2>&1; then
    ok "server $SERVER_NAME already exists"
  else
    log "creating server $SERVER_NAME ($SERVER_TYPE, $OS_IMAGE, $LOCATION) …"
    local ssh_args=""
    for key_id in $SSH_KEY_IDS; do
      ssh_args="$ssh_args --ssh-key $key_id"
    done
    # shellcheck disable=SC2086  # word-splitting on ssh_args is intentional
    hcloud server create \
      --name "$SERVER_NAME" \
      --type "$SERVER_TYPE" \
      --image "$OS_IMAGE" \
      --location "$LOCATION" \
      --network "$NETWORK_ID" \
      $ssh_args \
      --label role=bb-central \
      --label project=psmdb-buildbarn
    ok "server created"
  fi

  local srv_json
  srv_json=$(hcloud server describe "$SERVER_NAME" -o json)
  PUBLIC_IP=$(jq -r '.public_net.ipv4.ip' <<<"$srv_json")
  PRIVATE_IP=$(jq -r '.private_net[0].ip' <<<"$srv_json")
  [[ -n "$PUBLIC_IP"  && "$PUBLIC_IP"  != "null" ]] || die "could not read public IP"
  [[ -n "$PRIVATE_IP" && "$PRIVATE_IP" != "null" ]] || die "could not read private IP"
  ok "public IP:  $PUBLIC_IP"
  ok "private IP: $PRIVATE_IP"
}

# -----------------------------------------------------------------------------
# Attach volume if not already attached. Expected to be idempotent.
# -----------------------------------------------------------------------------
attach_volume() {
  step "Volume"

  local vol_server
  vol_server=$(hcloud volume describe "$VOLUME_ID" -o json | jq -r '.server // empty')
  if [[ -n "$vol_server" && "$vol_server" != "null" ]]; then
    ok "volume already attached (server id $vol_server)"
    return
  fi

  log "attaching volume $VOLUME_ID to $SERVER_NAME (automount disabled — we'll handle fstab ourselves) …"
  hcloud volume attach --server "$SERVER_NAME" --automount=false "$VOLUME_ID"
  ok "volume attached"
}

# -----------------------------------------------------------------------------
# Wait for SSH to be reachable, then prime known_hosts.
# -----------------------------------------------------------------------------
SSH_OPTS=""
wait_for_ssh() {
  step "SSH reachability"

  log "waiting for $PUBLIC_IP:22 …"
  for _ in {1..60}; do
    if ssh -i "$SSH_PRIV_KEY" \
           -o StrictHostKeyChecking=accept-new \
           -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
           -o BatchMode=yes \
           -o ConnectTimeout=5 \
           "root@$PUBLIC_IP" true 2>/dev/null; then
      ok "SSH ready"
      SSH_OPTS="-i $SSH_PRIV_KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HOME/.ssh/known_hosts"
      return
    fi
    sleep 3
  done
  die "SSH didn't come up within 3 minutes"
}

# Thin wrapper: run arbitrary bash on the central host.
rssh() {
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "root@$PUBLIC_IP" "$@"
}

rrsync() {
  # shellcheck disable=SC2086
  rsync -a --delete -e "ssh $SSH_OPTS" "$@"
}

# -----------------------------------------------------------------------------
# Install Docker (get.docker.com) and ancillary tools.
# -----------------------------------------------------------------------------
bootstrap_host() {
  step "Host packages"

  rssh 'bash -se' <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v docker >/dev/null 2>&1; then
  echo "  installing docker via get.docker.com …"
  curl -fsSL https://get.docker.com | sh
else
  echo "  docker already installed: $(docker --version)"
fi

# compose plugin is bundled with the get.docker.com install but double-check.
if ! docker compose version >/dev/null 2>&1; then
  apt-get update
  apt-get install -y docker-compose-plugin
fi

# rsync is required so we can push configs from the operator's laptop;
# xfsprogs so wipe-attach can mkfs.xfs the volume; jq for operator convenience.
apt-get update
apt-get install -y rsync jq xfsprogs

systemctl enable --now docker
REMOTE
  ok "host packaged prepared"
}

# -----------------------------------------------------------------------------
# Mount the volume at /var/lib/buildbarn (if not already mounted) and ensure
# there's an fstab entry so reboots don't unmount it.
# -----------------------------------------------------------------------------
mount_volume() {
  step "Mount volume"

  rssh "VOLUME_DEV='$VOLUME_DEV' REMOTE_BASE='$REMOTE_BASE' bash -se" <<'REMOTE'
set -euo pipefail
mkdir -p "$REMOTE_BASE"

if ! [[ -e "$VOLUME_DEV" ]]; then
  echo "  ! volume device not found at $VOLUME_DEV" >&2
  echo "    (Hetzner attach may be async; listing /dev/disk/by-id for diagnosis:)" >&2
  ls -la /dev/disk/by-id/ >&2 || true
  exit 1
fi

# Detect filesystem. If blkid says nothing, the device is raw — can't happen
# with our workflow (we used `hcloud volume create --format xfs`) but catch
# it defensively and leave the decision to the operator rather than
# silently formatting.
FS_TYPE=$(blkid -o value -s TYPE "$VOLUME_DEV" || true)
if [[ -z "$FS_TYPE" ]]; then
  echo "  ✗ volume at $VOLUME_DEV has no filesystem — aborting." >&2
  echo "    Run \`mkfs.xfs $VOLUME_DEV\` manually or re-create the volume with --format xfs." >&2
  exit 1
fi
if [[ "$FS_TYPE" != "xfs" ]]; then
  echo "  ✗ volume has unexpected filesystem '$FS_TYPE' (expected xfs) — aborting." >&2
  exit 1
fi

if mountpoint -q "$REMOTE_BASE"; then
  echo "  ✓ $REMOTE_BASE already mounted"
else
  mount -t xfs -o noatime "$VOLUME_DEV" "$REMOTE_BASE"
  echo "  ✓ mounted $VOLUME_DEV at $REMOTE_BASE"
fi

# fstab: use the by-id symlink so the entry survives Hetzner detach/reattach.
FSTAB_LINE="$VOLUME_DEV $REMOTE_BASE xfs noatime,nofail 0 0"
if ! grep -qF "$VOLUME_DEV" /etc/fstab; then
  echo "$FSTAB_LINE" >> /etc/fstab
  echo "  ✓ added fstab entry"
fi
REMOTE
  ok "volume mounted at $REMOTE_BASE"
}

# -----------------------------------------------------------------------------
# Detect whether the volume has already been bootstrapped. Returns:
#   populated | fresh
# via stdout.
# -----------------------------------------------------------------------------
detect_state() {
  rssh "REMOTE_BASE='$REMOTE_BASE' bash -se" <<'REMOTE'
set -euo pipefail
if [[ -f "$REMOTE_BASE/compose/docker-compose.yml" ]] \
   || compgen -G "$REMOTE_BASE/storage-cas-*/blocks" >/dev/null; then
  echo populated
else
  echo fresh
fi
REMOTE
}

# -----------------------------------------------------------------------------
# Interactive prompt for populated volume. Sets MODE to one of:
#   attach | wipe-attach | abort
# -----------------------------------------------------------------------------
prompt_mode() {
  if [[ -n "$MODE" ]]; then
    log "MODE=$MODE (pre-set via env)"
    case "$MODE" in
      attach|wipe-attach|abort) return ;;
      *) die "invalid MODE='$MODE' — expected attach|wipe-attach|abort" ;;
    esac
  fi

  cat <<EOF

The volume at $REMOTE_BASE is already populated. Choose:

  attach       Keep existing CAS/AC/FSAC data (warm cache survives). Only
               the compose file, jsonnet configs, and reapi-proxy sources
               are refreshed from the local repo. .env is rewritten with
               the server's current public/private IPs.

  wipe-attach  mkfs.xfs the volume (DESTROYS all cached artefacts) and do
               a fresh bootstrap. Use this after an incompatible bb-storage
               upgrade or suspected CAS corruption.

  abort        Leave everything as-is. No further changes. You can SSH in
               manually to investigate.

EOF
  local reply
  while true; do
    read -rp "Select [attach/wipe-attach/abort]: " reply
    case "$reply" in
      attach|wipe-attach|abort) MODE="$reply"; return ;;
      *) echo "  (please type one of: attach, wipe-attach, abort)" ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Wipe the volume (inside wipe-attach mode). Tears down containers, unmounts,
# mkfs, remounts.
# -----------------------------------------------------------------------------
wipe_volume() {
  step "Wipe volume"

  warn "this destroys all data on $VOLUME_DEV. You have 5 seconds to Ctrl-C."
  sleep 5

  rssh "REMOTE_BASE='$REMOTE_BASE' VOLUME_DEV='$VOLUME_DEV' REMOTE_COMPOSE='$REMOTE_COMPOSE' bash -se" <<'REMOTE'
set -euo pipefail

if [[ -f "$REMOTE_COMPOSE/docker-compose.yml" ]]; then
  ( cd "$REMOTE_COMPOSE" && docker compose down -v --remove-orphans || true )
fi

# Flush any pending writes, then try unmounting. The umount can fail if a
# stray shell or editor has cwd under /var/lib/buildbarn (often an operator's
# second SSH session that was used for diagnostics).
sync

if mountpoint -q "$REMOTE_BASE"; then
  if ! umount "$REMOTE_BASE" 2>/dev/null; then
    echo "  ! /var/lib/buildbarn is busy — processes currently holding it:" >&2
    fuser -vm "$REMOTE_BASE" 2>&1 || true
    echo "  ! aborting wipe. Close whatever's shown above (e.g. 'cd /' in the" >&2
    echo "    other SSH session), then re-run with MODE=wipe-attach." >&2
    exit 1
  fi
fi

mkfs.xfs -f "$VOLUME_DEV"
mount -t xfs -o noatime "$VOLUME_DEV" "$REMOTE_BASE"
echo "  ✓ volume wiped and remounted"
REMOTE
  ok "volume wiped"
}

# -----------------------------------------------------------------------------
# Create the storage dirs if missing, rsync configs, write .env, sed the
# browserUrl placeholder.
# -----------------------------------------------------------------------------
sync_configs() {
  step "Sync configs"

  # 1) Create skeleton of state dirs. Safe in attach mode (existing dirs are
  #    left alone), mandatory in fresh/wipe-attach mode.
  rssh "REMOTE_BASE='$REMOTE_BASE' bash -se" <<'REMOTE'
set -euo pipefail
for shard in 0 1; do
  for kind in cas ac fsac; do
    # bb-storage auto-creates `blocks` and `key_location_map` files if they
    # are missing, but it will NOT create the persistent_state directory —
    # it only opens it. So create both the shard root and the subdir.
    mkdir -p "$REMOTE_BASE/storage-$kind-$shard/persistent_state"
  done
done
mkdir -p "$REMOTE_BASE/compose" "$REMOTE_BASE/reapi-proxy"
REMOTE
  ok "state dirs in place"

  # 2) In attach mode, snapshot existing compose/ and reapi-proxy/ before
  #    overwriting them — cheap and makes rollback trivial.
  if [[ "$MODE" == "attach" ]]; then
    local ts; ts=$(date +%Y%m%dT%H%M%S)
    rssh "REMOTE_BASE='$REMOTE_BASE' TS='$ts' bash -se" <<'REMOTE'
set -euo pipefail
BACKUP="$REMOTE_BASE/_backups/$TS"
mkdir -p "$BACKUP"
[[ -d "$REMOTE_BASE/compose" ]]     && cp -a "$REMOTE_BASE/compose"     "$BACKUP/" || true
[[ -d "$REMOTE_BASE/reapi-proxy" ]] && cp -a "$REMOTE_BASE/reapi-proxy" "$BACKUP/" || true
echo "  ✓ snapshot at $BACKUP"
REMOTE
  fi

  # 3) Push compose/ and reapi-proxy/ from the local repo.
  log "rsync compose/ → $REMOTE_COMPOSE"
  rrsync \
    --exclude=.env \
    "$COMPOSE_SRC/" "root@$PUBLIC_IP:$REMOTE_COMPOSE/"

  log "rsync reapi-proxy/ → $REMOTE_REAPI"
  rrsync \
    --exclude=docker-compose.yml \
    "$REAPI_PROXY_SRC/" "root@$PUBLIC_IP:$REMOTE_REAPI/"

  ok "configs synced"

  # 4) Write .env with current IPs, sed the browserUrl placeholder.
  rssh "REMOTE_COMPOSE='$REMOTE_COMPOSE' PRIVATE_IP='$PRIVATE_IP' PUBLIC_IP='$PUBLIC_IP' bash -se" <<'REMOTE'
set -euo pipefail

cat > "$REMOTE_COMPOSE/.env" <<EOF
# Generated by create-central.sh — edit by hand if you know what you're doing.
# Tags below mirror the currently-working barn-psmdb control plane.
BB_STORAGE_TAG=20260326T151518Z-d0c6f26
BB_SCHEDULER_TAG=20260326T163248Z-e6ab874
BB_BROWSER_TAG=20260319T101727Z-1731858
ENVOY_IMAGE_TAG=v1.31-latest
PRIVATE_IP=$PRIVATE_IP
EOF

# Replace the __BB_PUBLIC_URL__ placeholder in the jsonnet library so the
# scheduler admin UI, browser, and frontend all emit links that work from the
# operator's laptop. Using the public IP on port 7984 matches how bb-browser
# is exposed in docker-compose.yml.
sed -i "s|__BB_PUBLIC_URL__|http://$PUBLIC_IP:7984|g" \
  "$REMOTE_COMPOSE/config/common.libsonnet"

echo "  ✓ .env and browserUrl substitution done"
REMOTE
  ok "environment baked in"
}

# -----------------------------------------------------------------------------
# Build reapi-proxy image, pull upstream images, bring the stack up.
# -----------------------------------------------------------------------------
compose_up() {
  step "docker compose up"

  rssh "REMOTE_COMPOSE='$REMOTE_COMPOSE' bash -se" <<'REMOTE'
set -euo pipefail
cd "$REMOTE_COMPOSE"

docker compose build reapi-proxy
docker compose pull --ignore-buildable
docker compose up -d

echo
echo "  === docker compose ps ==="
docker compose ps
REMOTE
  ok "stack running"
}

# -----------------------------------------------------------------------------
# Minimal smoke tests. Not a full integration test — that's Phase 1 of the
# roadmap. Here we just verify that the ports we expect to be serving are
# actually responding.
# -----------------------------------------------------------------------------
smoke() {
  step "Smoke tests"

  # 7982 = scheduler admin HTML UI (public).
  if curl -sSf -m 5 "http://$PUBLIC_IP:7982/" >/dev/null; then
    ok "scheduler admin UI reachable on http://$PUBLIC_IP:7982"
  else
    warn "scheduler admin UI at http://$PUBLIC_IP:7982 not responding"
  fi

  # 7984 = browser (public).
  if curl -sSf -m 5 "http://$PUBLIC_IP:7984/" >/dev/null; then
    ok "bb-browser reachable on http://$PUBLIC_IP:7984"
  else
    warn "bb-browser at http://$PUBLIC_IP:7984 not responding"
  fi

  # 8981 = Envoy for Bazel clients. A bare TCP dial is enough to prove the
  # gateway is up without pulling in a grpc client — reachability alone is
  # the real signal here, and Envoy closes the connection on non-gRPC
  # traffic, which is fine for `nc -z`.
  if rssh "timeout 3 bash -c ':> /dev/tcp/127.0.0.1/8981' 2>/dev/null"; then
    ok "envoy-proxy accepting connections on :8981"
  else
    warn "envoy-proxy NOT accepting on :8981 — check 'docker compose logs envoy-proxy'"
  fi
}

# -----------------------------------------------------------------------------
# Summary.
# -----------------------------------------------------------------------------
summary() {
  cat <<EOF

\033[1;32mbb-psmdb-ondemand central node ready.\033[0m

  Public:
    SSH              : ssh -i $SSH_PRIV_KEY root@$PUBLIC_IP
    Scheduler admin  : http://$PUBLIC_IP:7982/
    bb-browser       : http://$PUBLIC_IP:7984/
    Bazel clients    : grpc://$PUBLIC_IP:8981         (no TLS/auth, matches barn-psmdb)

  Private (network 11374636 / psmdb.cd.percona.com):
    Worker gRPC      : grpc://$PRIVATE_IP:8983        (ondemand workers only)

  Localhost (on central host only):
    BuildQueueState  : grpc://127.0.0.1:8984          (scaler consumes this)

  Next steps:
    * Phase 1: spawn a worker with scripts/spawn-worker.sh once it exists.
    * Phase 2: wire the scaler daemon to grpc://127.0.0.1:8984.
    * Point Bazel clients at --remote_executor=grpc://$PUBLIC_IP:8981
EOF
}

# -----------------------------------------------------------------------------
# Main.
# -----------------------------------------------------------------------------
main() {
  preflight
  ensure_server
  attach_volume
  wait_for_ssh
  bootstrap_host
  mount_volume

  local state
  state=$(detect_state)
  log "volume state: $state"

  case "$state" in
    fresh)
      MODE=${MODE:-bootstrap}
      ;;
    populated)
      prompt_mode
      if [[ "$MODE" == "abort" ]]; then
        warn "aborted by operator; the server and volume are untouched."
        exit 0
      fi
      if [[ "$MODE" == "wipe-attach" ]]; then
        wipe_volume
      fi
      ;;
  esac

  sync_configs
  compose_up
  smoke
  summary
}

main "$@"
