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

# Public hostname under which the central is reachable from operator laptops
# and CI runners. Must match the SAN on the TLS cert served by Envoy
# (gRPC :8981), bb-browser (:7984), and bb-scheduler admin UI (:7982).
# Required because TLS certs are issued for DNS names — `https://<ip>:port`
# would never validate. The script uses this value to:
#
#   * sed the __BB_PUBLIC_URL__ placeholder in common.libsonnet
#     (→ https://$PUBLIC_HOSTNAME:7984)
#   * build the public summary printed at the end of the run
#
# The matching cert is provisioned out-of-band (certbot + HTTP-01 on :80)
# and stored under /var/lib/buildbarn/certs/. See buildbarn-auth-tls-plan.md
# §4 for the full TLS layout.
: "${PUBLIC_HOSTNAME:=}"

# -----------------------------------------------------------------------------
# Repo paths (resolved relative to this script so the tool can be invoked from
# any CWD).
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONDEMAND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_SRC="$ONDEMAND_DIR/compose"
WORKER_SRC="$ONDEMAND_DIR/worker"
SCALER_SRC="$ONDEMAND_DIR/scaler"
REAPI_PROXY_SRC="$(cd "$ONDEMAND_DIR/../reapi-proxy" && pwd)"

# Remote paths on the central host.
REMOTE_BASE=/var/lib/buildbarn
REMOTE_COMPOSE="$REMOTE_BASE/compose"
REMOTE_REAPI="$REMOTE_BASE/reapi-proxy"
REMOTE_WORKER="$REMOTE_BASE/worker"
REMOTE_SCALER="$REMOTE_BASE/scaler"
VOLUME_DEV="/dev/disk/by-id/scsi-0HC_Volume_${VOLUME_ID}"

# Hetzner Cloud API token for the scaler daemon. Must be scoped to the
# psmdb-buildbarn project with read+write on servers / networks / SSH keys.
#
# Resolution order (first non-empty wins):
#   1. $HCLOUD_TOKEN env var (same one hcloud CLI reads)
#   2. $HCLOUD_TOKEN_FILE pointing at a file containing just the token
#   3. $HCLOUD_CONFIG (cli.toml), context name = $HCLOUD_CONTEXT_NAME;
#      fails loudly if the file has no such context
#   4. interactive password prompt
#
# There is intentionally NO silent fallback to cli.toml's `active_context`:
# operators with multiple contexts (personal, other projects, this project)
# must pin HCLOUD_CONTEXT_NAME explicitly, otherwise a wrong active context
# in the operator's shell would silently ship the wrong project's token.
: "${HCLOUD_TOKEN:=}"
: "${HCLOUD_TOKEN_FILE:=}"
: "${HCLOUD_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/hcloud/cli.toml}"
: "${HCLOUD_CONTEXT_NAME:=}"

# -----------------------------------------------------------------------------
# Pretty logging.
# -----------------------------------------------------------------------------
log()   { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m  ! %s\033[0m\n' "$*"; }
die()   { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }
step()  { printf '\n\033[1;35m=== %s ===\033[0m\n' "$*"; }

# -----------------------------------------------------------------------------
# Extract a token from hcloud CLI's cli.toml by context name.
#
# File format (stable across recent hcloud CLI versions):
#
#     active_context = "my-ctx"
#
#     [[contexts]]
#     name = "my-ctx"
#     token = "xxxxx..."
#
#     [[contexts]]
#     name = "other-ctx"
#     token = "yyyy..."
#
# Usage: _hcloud_token_from_cli_config <context-name>
#
# Prints the token to stdout (empty string + exit 0 on miss or unreadable
# file). We intentionally do NOT fall back to active_context if the named
# context is absent — caller is expected to treat an empty result as fatal.
# Using awk keeps the dependency footprint the same as the rest of this
# script — no python/toml required.
# -----------------------------------------------------------------------------
# TOML strings come in both `"..."` (basic) and `'...'` (literal) forms —
# hcloud CLI's current serializer emits literal strings, older versions emit
# basic strings. Accept both so the parser survives across cli versions.
_hcloud_token_from_cli_config() {
  local cfg="$HCLOUD_CONFIG"
  local want="${1:?context name required}"
  [[ -r "$cfg" ]] || return 0
  # NB: no apostrophes in the awk body — the whole program is wrapped in
  # single quotes by the shell, and even inside an awk #-comment bash would
  # still see a stray `'\''` and close the string. Keep comments apostrophe-free.
  awk -v want="$want" '
    BEGIN { in_ctx=0; name=""; token=""; printed=0 }
    function unquote(v,    _) {
      sub(/.*=[[:space:]]*/, "", v)
      sub(/[[:space:]]*$/,   "", v)
      if      (v ~ /^".*"$/)       { sub(/^"/,   "", v); sub(/"$/,   "", v) }
      else if (v ~ /^'\''.*'\''$/) { sub(/^'\''/,"", v); sub(/'\''$/,"", v) }
      return v
    }
    function flush() {
      if (in_ctx && name == want && token != "") {
        print token
        printed = 1
        exit
      }
      in_ctx=1; name=""; token=""
    }
    /^[[:space:]]*\[\[contexts\]\][[:space:]]*$/ { flush(); next }
    in_ctx && /^[[:space:]]*name[[:space:]]*=/  { name  = unquote($0); next }
    in_ctx && /^[[:space:]]*token[[:space:]]*=/ { token = unquote($0); next }
    END {
      if (!printed && in_ctx && name == want && token != "") print token
    }
  ' "$cfg"
}

# List all context names in cli.toml, one per line. Used for helpful error
# messages when HCLOUD_CONTEXT_NAME doesnt match anything in the file.
_hcloud_list_cli_contexts() {
  local cfg="$HCLOUD_CONFIG"
  [[ -r "$cfg" ]] || return 0
  awk '
    function unquote(v,    _) {
      sub(/.*=[[:space:]]*/, "", v)
      sub(/[[:space:]]*$/,   "", v)
      if (v ~ /^".*"$/) { sub(/^"/,"",v); sub(/"$/,"",v) }
      else if (v ~ /^'\''.*'\''$/) { sub(/^'\''/,"",v); sub(/'\''$/,"",v) }
      return v
    }
    /^[[:space:]]*\[\[contexts\]\][[:space:]]*$/ { in_ctx=1; next }
    in_ctx && /^[[:space:]]*name[[:space:]]*=/ { print unquote($0); in_ctx=0 }
  ' "$cfg"
}

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
  [[ -d "$WORKER_SRC" ]]       || die "worker source missing: $WORKER_SRC"
  [[ -f "$WORKER_SRC/docker-compose.yml" ]] \
    || die "worker/docker-compose.yml missing"
  [[ -d "$SCALER_SRC" ]]       || die "scaler source missing: $SCALER_SRC"
  [[ -f "$SCALER_SRC/Dockerfile" ]] \
    || die "scaler/Dockerfile missing"
  [[ -f "$SCALER_SRC/scaler.py" ]] \
    || die "scaler/scaler.py missing"
  [[ -f "$COMPOSE_SRC/config/ondemand-pools.yaml" ]] \
    || die "compose/config/ondemand-pools.yaml missing"
  [[ -f "$COMPOSE_SRC/config/scheduler.jsonnet" ]] \
    || die "compose/config/scheduler.jsonnet missing"
  ok "repo layout OK"

  # PUBLIC_HOSTNAME is required so the in-jsonnet browserUrl points at the
  # TLS-served https endpoint. Refusing to default to PUBLIC_IP is intentional:
  # an IP-based URL would never validate against the Let's Encrypt cert
  # provisioned for the DNS name, and we'd silently serve broken UI links.
  [[ -n "$PUBLIC_HOSTNAME" ]] \
    || die "PUBLIC_HOSTNAME env var is required (e.g. PUBLIC_HOSTNAME=bb-psmdb.ddns.net) — see buildbarn-auth-tls-plan.md §4"
  ok "public hostname: $PUBLIC_HOSTNAME"

  # NB: there used to be a preflight drift check here — it verified that
  # every routing-key entry in ondemand-pools.yaml also appeared in
  # scheduler.jsonnet's predeclaredPlatformQueues. That check was
  # obsoleted by bake_predeclared() (see below), which GENERATES
  # predeclared.libsonnet from the YAML at deploy time — the two are
  # in sync by construction now, so there's nothing to drift.

  # HCLOUD_TOKEN is required by the scaler. Try sources in order so a
  # correctly-configured operator (hcloud CLI authenticated, or token in env)
  # is NEVER prompted. Only the very first-run laptop should hit the prompt.
  local token_src=""
  if [[ -n "$HCLOUD_TOKEN" ]]; then
    token_src="env:HCLOUD_TOKEN"
  fi
  if [[ -z "$HCLOUD_TOKEN" && -n "$HCLOUD_TOKEN_FILE" ]]; then
    [[ -r "$HCLOUD_TOKEN_FILE" ]] || die "HCLOUD_TOKEN_FILE not readable: $HCLOUD_TOKEN_FILE"
    HCLOUD_TOKEN=$(tr -d '\r\n' < "$HCLOUD_TOKEN_FILE")
    token_src="file:$HCLOUD_TOKEN_FILE"
  fi
  # cli.toml lookup — only when HCLOUD_CONTEXT_NAME is explicitly set.
  # No silent active_context fallback: the active context in the operator's
  # shell is unrelated to this project and could belong to a different
  # Hetzner project entirely — shipping that token would mis-scale somebody
  # else's infra.
  if [[ -z "$HCLOUD_TOKEN" && -n "$HCLOUD_CONTEXT_NAME" ]]; then
    [[ -r "$HCLOUD_CONFIG" ]] \
      || die "HCLOUD_CONTEXT_NAME=$HCLOUD_CONTEXT_NAME set but $HCLOUD_CONFIG is not readable"
    HCLOUD_TOKEN=$(_hcloud_token_from_cli_config "$HCLOUD_CONTEXT_NAME" || true)
    if [[ -z "$HCLOUD_TOKEN" ]]; then
      warn "HCLOUD_CONTEXT_NAME=$HCLOUD_CONTEXT_NAME not found in $HCLOUD_CONFIG"
      warn "known contexts in this file:"
      _hcloud_list_cli_contexts | sed 's/^/    - /' >&2 || true
      die  "no matching context — set HCLOUD_CONTEXT_NAME to one of the above"
    fi
    token_src="cli.toml:$HCLOUD_CONTEXT_NAME"
  fi
  if [[ -z "$HCLOUD_TOKEN" ]]; then
    warn "no token from env/file/cli.toml — export HCLOUD_TOKEN, set HCLOUD_TOKEN_FILE,"
    warn "or set HCLOUD_CONTEXT_NAME to a named context in $HCLOUD_CONFIG"
    read -rsp "Paste HCLOUD_TOKEN (input hidden): " HCLOUD_TOKEN; echo
    token_src="prompt"
  fi
  [[ -n "$HCLOUD_TOKEN" ]] || die "HCLOUD_TOKEN is empty — aborting"
  # Loose sanity: Hetzner tokens are 64 chars of alphanumerics. Don't fail
  # hard on length drift — just warn, because token formats could evolve.
  if ! [[ "$HCLOUD_TOKEN" =~ ^[A-Za-z0-9]{40,}$ ]]; then
    warn "HCLOUD_TOKEN doesn't look like a typical Hetzner token — proceeding anyway"
  fi
  ok "HCLOUD_TOKEN captured (${#HCLOUD_TOKEN} chars, source=$token_src)"

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
# xfsprogs so wipe-attach can mkfs.xfs the volume; jq for operator
# convenience; python3-yaml for bake_env()'s predeclared.libsonnet
# generator (parses ondemand-pools.yaml → emits jsonnet-compatible JSON).
apt-get update
apt-get install -y rsync jq xfsprogs python3-yaml

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
# -----------------------------------------------------------------------------
# Generate (if missing) an SSH keypair on the central, register its pubkey
# with Hetzner as a named SSH key, and install an `ssh-worker` wrapper on
# the central for convenient debugging.
#
# Why: workers are spawned with `--ssh-key` tying a set of Hetzner key ids
# into their authorized_keys at VM-create time — but Hetzner has NO API for
# adding SSH keys to an existing VM. So unless the central's key was among
# those keys when the worker was created, the central can never ssh into
# that worker (not even over the private network). Long-term the public IPs
# on workers will be removed, and from-laptop debug becomes impossible; the
# central must be able to ssh into workers via the private network.
#
# Idempotency:
#   * `/root/.ssh/id_ed25519` on central: generated only if missing. The
#     keypair survives volume detach/reattach because /root lives on the
#     boot disk, not on the XFS volume — but a fresh VM (ensure_server
#     replaced the server) gets a new key, and the Hetzner-side named key
#     is rotated to match.
#   * Hetzner named SSH key `bb-psmdb-ondemand-central`: describe → create;
#     if exists with different pubkey we delete + recreate. Existing
#     workers that were spawned under the OLD key id do NOT inherit the
#     rotated one — they'd need to be recycled (idle-reap suffices, or
#     `hcloud server delete` them manually).
#   * ssh-worker wrapper: re-written every deploy (tiny file, no risk).
# -----------------------------------------------------------------------------
ensure_central_ssh_key() {
  step "Central SSH key for worker access"

  # 1. Generate keypair on central (idempotent).
  rssh 'bash -se' <<'REMOTE'
set -euo pipefail
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [[ ! -f /root/.ssh/id_ed25519 ]]; then
  # Empty passphrase — the key sits on root-owned 0600 file on a VM the
  # operator already trusts as the Bazel control plane. Adding a passphrase
  # here would just require hardcoding it somewhere even less safe.
  ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519 -C 'bb-psmdb-ondemand-central' >/dev/null
  echo "  generated new ed25519 keypair"
else
  echo "  keypair already present"
fi
chmod 600 /root/.ssh/id_ed25519
chmod 644 /root/.ssh/id_ed25519.pub
REMOTE
  ok "central keypair present on $PUBLIC_IP"

  # 2. Pull the pubkey back to the laptop so we can reconcile with Hetzner.
  local central_pubkey
  central_pubkey=$(rssh 'cat /root/.ssh/id_ed25519.pub')
  [[ -n "$central_pubkey" ]] || die "could not read central's pubkey"

  # 3. Reconcile with Hetzner named SSH key. Three cases:
  #      absent   → create
  #      present-match → noop
  #      present-mismatch → delete + create (pubkey drift: rotating key)
  local key_name="bb-psmdb-ondemand-central"
  local existing_json existing_pub
  if existing_json=$(hcloud ssh-key describe "$key_name" -o json 2>/dev/null); then
    existing_pub=$(jq -r '.public_key' <<<"$existing_json")
    # Hetzner stores pubkeys with a trailing newline; operator laptop `cat`
    # may or may not carry one. Strip both sides before comparing.
    if [[ "${existing_pub%$'\n'}" == "${central_pubkey%$'\n'}" ]]; then
      ok "Hetzner SSH key '$key_name' already matches central's pubkey"
    else
      warn "Hetzner SSH key '$key_name' exists but pubkey differs — rotating"
      hcloud ssh-key delete "$key_name" >/dev/null
      hcloud ssh-key create --name "$key_name" --public-key "$central_pubkey" >/dev/null
      ok "Hetzner SSH key '$key_name' rotated"
    fi
  else
    log "creating Hetzner SSH key '$key_name' …"
    hcloud ssh-key create --name "$key_name" --public-key "$central_pubkey" >/dev/null
    ok "Hetzner SSH key '$key_name' created"
  fi

  # 4. Resolve numeric id so sync_configs() can inject it into the baked
  #    ondemand-pools.yaml (scaler + spawn-worker.sh both read the list
  #    from there — one source of truth for which keys land in workers).
  CENTRAL_SSH_KEY_ID=$(hcloud ssh-key describe "$key_name" -o format='{{.ID}}')
  [[ -n "$CENTRAL_SSH_KEY_ID" ]] || die "could not resolve SSH key id for '$key_name'"
  ok "Hetzner SSH key id: $CENTRAL_SSH_KEY_ID"

  # 5. Install the ssh-worker wrapper on central. Workers are ephemeral
  #    (Hetzner aggressively recycles public IPv4s and we redeploy
  #    private IPs constantly), so we pin StrictHostKeyChecking=no +
  #    UserKnownHostsFile=/dev/null — recording host keys would cause
  #    silent "host key changed" failures on IP-recycled spawns.
  rssh 'bash -se' <<'REMOTE'
set -euo pipefail
cat > /usr/local/bin/ssh-worker <<'WRAP'
#!/usr/bin/env bash
# ssh-worker <ip-or-host> [cmd …]
#
# Central-side convenience wrapper for SSH into ondemand workers (spawned
# by scaler.py via the Hetzner cloud API, or manually via spawn-worker.sh).
# Workers trust /root/.ssh/id_ed25519.pub via the Hetzner-registered key
# `bb-psmdb-ondemand-central`, which create-central.sh injects into every
# newly-spawned worker's authorized_keys at VM-create time.
#
# Host keys are DISCARDED — workers are throwaway by design, and recording
# them would cause "host key changed" failures on every IP recycle.
set -euo pipefail
target="${1:?usage: ssh-worker <ip-or-host> [cmd …]}"
shift
exec ssh \
  -i /root/.ssh/id_ed25519 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  "root@$target" "$@"
WRAP
chmod +x /usr/local/bin/ssh-worker
echo "  ssh-worker wrapper installed at /usr/local/bin/ssh-worker"
REMOTE
  ok "ssh-worker wrapper installed — run e.g. 'ssh-worker 10.30.242.42 docker compose ps' on central"
}

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
mkdir -p "$REMOTE_BASE/compose" "$REMOTE_BASE/reapi-proxy" "$REMOTE_BASE/worker" "$REMOTE_BASE/scaler"
REMOTE
  ok "state dirs in place"

  # 2) In attach mode, snapshot existing compose/, reapi-proxy/, worker/,
  #    and scaler/ before overwriting them — cheap and makes rollback trivial.
  if [[ "$MODE" == "attach" ]]; then
    local ts; ts=$(date +%Y%m%dT%H%M%S)
    rssh "REMOTE_BASE='$REMOTE_BASE' TS='$ts' bash -se" <<'REMOTE'
set -euo pipefail
BACKUP="$REMOTE_BASE/_backups/$TS"
mkdir -p "$BACKUP"
[[ -d "$REMOTE_BASE/compose" ]]     && cp -a "$REMOTE_BASE/compose"     "$BACKUP/" || true
[[ -d "$REMOTE_BASE/reapi-proxy" ]] && cp -a "$REMOTE_BASE/reapi-proxy" "$BACKUP/" || true
[[ -d "$REMOTE_BASE/worker" ]]      && cp -a "$REMOTE_BASE/worker"      "$BACKUP/" || true
[[ -d "$REMOTE_BASE/scaler" ]]      && cp -a "$REMOTE_BASE/scaler"      "$BACKUP/" || true
echo "  ✓ snapshot at $BACKUP"
REMOTE
  fi

  # 3) Push compose/, reapi-proxy/, worker/, and scaler/ from the local repo.
  #    worker/ is the source of truth BOTH for spawn-worker.sh (rsyncs from
  #    laptop directly into the worker VM) AND for the scaler daemon (reads
  #    this directory read-only and inlines the rendered configs into the
  #    cloud-init user-data it hands to the Hetzner API). Shipping a single
  #    authoritative copy here prevents drift between the two spawn paths.
  log "rsync compose/ → $REMOTE_COMPOSE"
  rrsync \
    --exclude=.env \
    "$COMPOSE_SRC/" "root@$PUBLIC_IP:$REMOTE_COMPOSE/"

  log "rsync reapi-proxy/ → $REMOTE_REAPI"
  rrsync \
    --exclude=docker-compose.yml \
    "$REAPI_PROXY_SRC/" "root@$PUBLIC_IP:$REMOTE_REAPI/"

  log "rsync worker/ → $REMOTE_WORKER"
  rrsync \
    "$WORKER_SRC/" "root@$PUBLIC_IP:$REMOTE_WORKER/"

  log "rsync scaler/ → $REMOTE_SCALER"
  rrsync \
    --exclude=__pycache__ \
    "$SCALER_SRC/" "root@$PUBLIC_IP:$REMOTE_SCALER/"

  ok "configs synced"

  # 4) Write .env with current IPs + HCLOUD_TOKEN; sed the browserUrl
  #    placeholder in common.libsonnet; patch ondemand-pools.yaml with the
  #    central's own IPs (the YAML ships with `null` placeholders so a raw
  #    `git checkout` doesn't accidentally carry someone else's IPs) AND
  #    inject the central's own Hetzner SSH key id (resolved by
  #    ensure_central_ssh_key above) into global.hcloud_ssh_key_ids so
  #    newly-spawned workers accept SSH from the central.
  rssh \
    "REMOTE_COMPOSE='$REMOTE_COMPOSE'" \
    "PRIVATE_IP='$PRIVATE_IP'" \
    "PUBLIC_IP='$PUBLIC_IP'" \
    "PUBLIC_HOSTNAME='$PUBLIC_HOSTNAME'" \
    "HCLOUD_TOKEN='$HCLOUD_TOKEN'" \
    "CENTRAL_SSH_KEY_ID='$CENTRAL_SSH_KEY_ID'" \
    "bash -se" <<'REMOTE'
set -euo pipefail

# The .env file is not rsync'd from the laptop (see --exclude=.env above),
# so we write it from scratch here every run — the previous .env is
# snapshotted into $REMOTE_BASE/_backups/ during step 2.
#
# Two classes of keys in this file:
#   * Deploy-managed (image tags, PRIVATE_IP, HCLOUD_TOKEN) — always rewritten,
#     they describe the current stack and must match what `create-central.sh`
#     just built/uploaded.
#   * Operator-controlled (SCALER_DRY_RUN, SPAWN_THROTTLE_PER_POOL) — these
#     are runtime toggles SREs flip manually. Rewriting them on every run
#     silently resets the operator's decisions (e.g. flipping SCALER_DRY_RUN
#     back to `true` after the operator went live), which bit us on a
#     redeploy that put the scaler back into dry-run mid-build. So: if the
#     previous .env exists, pull those values forward; otherwise use the
#     safe defaults below (true / 1).
_prev=""
if [[ -f "$REMOTE_COMPOSE/.env" ]]; then _prev="$REMOTE_COMPOSE/.env"; fi
_env_get() {
  # Print the value of key "$1" from $_prev, or empty string if missing.
  # Intentionally simple: no quoting/escaping games — these are plain
  # boolean/integer knobs, nothing exotic. Prints first match only.
  [[ -n "$_prev" ]] || { echo ""; return; }
  awk -F= -v k="$1" '$1==k { sub(/^[^=]+=/, ""); print; exit }' "$_prev"
}
PREV_SCALER_DRY_RUN=$(_env_get SCALER_DRY_RUN)
PREV_SPAWN_THROTTLE=$(_env_get SPAWN_THROTTLE_PER_POOL)
: "${PREV_SCALER_DRY_RUN:=true}"
: "${PREV_SPAWN_THROTTLE:=1}"

cat > "$REMOTE_COMPOSE/.env" <<EOF
# Generated by create-central.sh — edit by hand if you know what you're doing.
# Tags below mirror the currently-working barn-psmdb control plane.
BB_STORAGE_TAG=20260326T151518Z-d0c6f26
BB_SCHEDULER_TAG=20260326T163248Z-e6ab874
BB_BROWSER_TAG=20260319T101727Z-1731858
ENVOY_IMAGE_TAG=v1.31-latest
PRIVATE_IP=$PRIVATE_IP
HCLOUD_TOKEN=$HCLOUD_TOKEN
# Safer default on a fresh install — scaler LOGS decisions instead of
# executing them. Operator flips this to \`false\` once they've watched a
# full queue-up / queue-drain cycle in the scaler logs without surprises.
# On re-runs this value is preserved from the previous .env above.
SCALER_DRY_RUN=$PREV_SCALER_DRY_RUN
# Cold-start throttle: max new VMs spawned per pool per tick. 1 = serial
# cold-starts (observe each VM register before the next); bump to e.g. 5 to
# warm up a full pool within one tick during a release matrix. Preserved
# across re-runs.
SPAWN_THROTTLE_PER_POOL=$PREV_SPAWN_THROTTLE
EOF
chmod 600 "$REMOTE_COMPOSE/.env"   # token inside; keep off `ls -l` casual reads.

# Replace the __BB_PUBLIC_URL__ placeholder in the jsonnet library so the
# scheduler admin UI, browser, and frontend all emit links that work from the
# operator's laptop. Uses the public DNS hostname (not the raw IP) on port
# 7984 over https so links match the TLS cert SAN — see buildbarn-auth-
# tls-plan.md §4. The cert is provisioned out-of-band by certbot and
# mounted into bb-browser at /etc/buildbarn/certs/.
sed -i "s|__BB_PUBLIC_URL__|https://$PUBLIC_HOSTNAME:7984|g" \
  "$REMOTE_COMPOSE/config/common.libsonnet"

# Patch ondemand-pools.yaml at bake time:
#
#   * scheduler_public_url / scheduler_private_ip — repo copy ships with
#     `null` placeholders so a clean `git checkout` doesn't carry stale
#     IPs; fill them with the current central's public+private now.
#   * hcloud_ssh_key_ids — append the central's own SSH key id (resolved
#     by ensure_central_ssh_key() earlier). Idempotent: if the id is
#     already in the list (e.g. on a redeploy where it was injected by
#     the previous run and then rsync'd back from repo — shouldn't
#     happen because we rsync FROM repo, but belt-and-suspenders) we
#     don't add a duplicate.
#
# We use yaml round-trip here instead of line-anchored sed because list
# mutation is awkward in sed and we already need python3-yaml on this
# host for the predeclared.libsonnet generator below. Comments in the
# baked copy are lost by safe_dump — acceptable; the operator reads the
# repo file for docs, the baked copy is an artifact consumed by the
# scaler which only cares about structure.
POOLS="$REMOTE_COMPOSE/config/ondemand-pools.yaml"
python3 - "$POOLS" "https://$PUBLIC_HOSTNAME:7982" "$PRIVATE_IP" "$CENTRAL_SSH_KEY_ID" <<'PY'
import sys, yaml
path, pub_url, priv_ip, key_id_str = sys.argv[1:5]
key_id = int(key_id_str)
with open(path) as fh:
    doc = yaml.safe_load(fh) or {}
g = doc.setdefault("global", {})
g["scheduler_public_url"] = pub_url
g["scheduler_private_ip"] = priv_ip
keys = g.setdefault("hcloud_ssh_key_ids", [])
if key_id not in keys:
    keys.append(key_id)
with open(path, "w") as fh:
    yaml.safe_dump(doc, fh, default_flow_style=False, sort_keys=False)
print(f"  ✓ ondemand-pools.yaml patched: public_url, private_ip, hcloud_ssh_key_ids (+{key_id})")
PY

# Generate config/predeclared.libsonnet from ondemand-pools.yaml. This is
# imported by scheduler.jsonnet and expands to `predeclaredPlatformQueues`
# at scheduler boot. Keeping the generator here (at bake time) — rather
# than inside scheduler.jsonnet via jsonnet's std.extVar / import — means
# the scheduler container stays untouched (no jsonnet-level YAML parsing,
# no extra libs) and the generated output is a plain human-readable JSON
# array you can diff or grep.
#
# Pool → predeclared entry mapping:
#   one entry per pool, with platform.properties =
#     [ Pool=<bazel_pool_value>,
#       container-image=docker://<runner_image>,
#       dockerNetwork=standard ]
#   and sizeClasses=[0].
#
# The container-image URL is the routing key — it MUST be byte-identical
# to what PSMDB's Bazel client emits (from psmdb_rbe_containers.bzl) and
# to what scaler/bootstrap.py substitutes into worker.jsonnet on each
# spawn. All three originate from runner_image in this YAML, so a single
# bump there propagates correctly.
#
# Output is pretty-printed JSON — valid jsonnet since JSON ⊂ jsonnet.
PREDECLARED_OUT="$REMOTE_COMPOSE/config/predeclared.libsonnet"
python3 - "$POOLS" "$PREDECLARED_OUT" <<'PY'
import json
import sys
import yaml

pools_path, out_path = sys.argv[1], sys.argv[2]
with open(pools_path) as fh:
    doc = yaml.safe_load(fh) or {}

entries = []
errors = []
for name, pool in (doc.get("pools") or {}).items():
    pool = pool or {}
    runner_image = pool.get("runner_image")
    bazel_pool = pool.get("bazel_pool_value")
    if not runner_image:
        errors.append(f"pool '{name}' missing runner_image")
        continue
    if not bazel_pool:
        errors.append(f"pool '{name}' missing bazel_pool_value")
        continue
    entries.append({
        "instanceNamePrefix": "hardlinking",
        "platform": {
            "properties": [
                {"name": "Pool", "value": bazel_pool},
                # `docker://` prefix is part of the contract that PSMDB's
                # psmdb_rbe_containers.bzl emits and that the worker's
                # worker.jsonnet substitutes — must match byte-for-byte.
                {"name": "container-image", "value": f"docker://{runner_image}"},
                {"name": "dockerNetwork", "value": "standard"},
            ],
        },
        # All our workers register with the default size_class (0); we
        # don't use feedback-driven size classification.
        "sizeClasses": [0],
    })

if errors:
    # Bail loudly rather than silently shipping a half-empty
    # predeclared.libsonnet. A single typo in a pool entry shouldn't take
    # down the whole queue set.
    for msg in errors:
        print(f"  ✗ {msg}", file=sys.stderr)
    sys.exit(1)

header = (
    "// AUTO-GENERATED by scripts/create-central.sh bake_env() from\n"
    "// config/ondemand-pools.yaml. DO NOT HAND-EDIT — edit the YAML and\n"
    "// redeploy. One entry per pool; routing key = docker://<runner_image>.\n"
)
with open(out_path, "w") as fh:
    fh.write(header)
    json.dump(entries, fh, indent=2)
    fh.write("\n")
print(f"  ✓ predeclared.libsonnet generated ({len(entries)} entries)")
PY

echo "  ✓ .env, browserUrl, ondemand-pools.yaml, and predeclared.libsonnet baked in"
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

docker compose build reapi-proxy scaler
docker compose pull --ignore-buildable
docker compose up -d

# Config-driven services (scheduler, scaler) bind-mount files from
# ./config/*. `docker compose up -d` only compares the *compose definition*
# (image tag, env, volumes), NOT the *content* of bind-mounted files — so
# an edit to scheduler.jsonnet or ondemand-pools.yaml would silently fail
# to take effect on a redeploy while the container reports "running". This
# bit us on the predeclaredPlatformQueues rollout: two successive redeploys
# appeared green but scheduler kept the previous (pre-predeclared) config
# and the first cold-start Bazel build hit FAILED_PRECONDITION because the
# predeclared queue was never actually registered. Explicit restart forces
# the process to re-exec and re-read its config files. On a fresh deploy
# this is a ~2s stop/start — acceptable overhead for correctness.
docker compose restart scheduler scaler

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

  # 7982 = scheduler admin HTML UI (public, https).
  # We hit it via the DNS hostname so the TLS cert SAN validates; the
  # alternative — curl https://<floating-ip>:7982 — would fail with
  # SSL_ERROR_BAD_CERTIFICATE_DOMAIN every time.
  if curl -sSf -m 5 "https://$PUBLIC_HOSTNAME:7982/" >/dev/null; then
    ok "scheduler admin UI reachable on https://$PUBLIC_HOSTNAME:7982"
  else
    warn "scheduler admin UI at https://$PUBLIC_HOSTNAME:7982 not responding"
  fi

  # 7984 = browser (public, https).
  if curl -sSf -m 5 "https://$PUBLIC_HOSTNAME:7984/" >/dev/null; then
    ok "bb-browser reachable on https://$PUBLIC_HOSTNAME:7984"
  else
    warn "bb-browser at https://$PUBLIC_HOSTNAME:7984 not responding"
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

  # Scaler: successful boot prints a "loaded config" line within the first
  # seconds. We look for that literal in the last ~60 lines rather than
  # assuming a specific port is open — the scaler has no externally exposed
  # listener in the MVP. grep -q returns non-zero when absent so we can
  # surface a clear warning pointing at the right logs.
  if rssh "REMOTE_COMPOSE='$REMOTE_COMPOSE' bash -c 'cd \$REMOTE_COMPOSE && docker compose logs --tail=60 scaler 2>/dev/null | grep -q \"loaded config\"'"; then
    # NB: actual SCALER_DRY_RUN value is preserved across redeploys — see
    # bake_env. Fresh install defaults to true (logs-only) for safety.
    ok "scaler booted and loaded config (mode shown in 'docker compose logs scaler')"
  else
    warn "scaler did NOT log 'loaded config' yet — check 'docker compose logs scaler'"
  fi

  # predeclaredPlatformQueues check: scheduler must expose one platform
  # queue per pool in ondemand-pools.yaml. If the observed count is
  # short, Bazel's first Execute against an affected pool hits
  # FAILED_PRECONDITION and the build dies on action #1 — the race this
  # whole predeclared-queue plumbing is there to close.
  #
  # Query runs inside the scaler container (ships grpcurl, has host
  # networking → can reach :8984 on localhost) — avoids the laptop
  # needing grpcurl at all.
  #
  # Counting strategy on the scheduler side: each PlatformQueueState has
  # a `sizeClassQueues` repeated field (JSON: "sizeClassQueues": [...]),
  # which appears exactly once per queue and is absent from all nested
  # fields (verified in bb-remote-execution buildqueuestate.proto:
  # PlatformQueueState message). That makes `grep -c "sizeClassQueues"` a
  # safe one-per-queue count even when a queue is brand-new with zero
  # size classes.
  #
  # Counting strategy on the YAML side: we count lines matching
  # `runner_image: "..."` — every pool entry is required to have this
  # field (load_config in scaler.py rejects pools without it), so the
  # line count is exactly the pool count. `awk` over `yq` is deliberate
  # — we don't want the laptop to need yq just to run this.
  local expected_queues
  expected_queues=$(awk '
    /^[[:space:]]{4}runner_image:[[:space:]]*"[^"]+"/ { count++ }
    END { print count+0 }
  ' "$COMPOSE_SRC/config/ondemand-pools.yaml")
  local actual_queues
  # `grep -c` exits 1 when there are zero matches — that would otherwise
  # trigger the outer `|| echo 0` and concatenate "0\n0" → "00". The
  # `|| true` inside the pipeline neutralises that without masking ssh or
  # grpcurl failures (both are upstream of grep). After the rssh we still
  # have the outer `|| echo 0` as a belt-and-braces fallback for the
  # ssh/grpcurl failure case.
  actual_queues=$(rssh "cd $REMOTE_COMPOSE && docker compose exec -T scaler grpcurl -plaintext localhost:8984 buildbarn.buildqueuestate.BuildQueueState/ListPlatformQueues 2>/dev/null | { grep -c sizeClassQueues || true; }" 2>/dev/null || echo 0)
  actual_queues=${actual_queues//[^0-9]/}
  : "${actual_queues:=0}"
  if (( actual_queues >= expected_queues )); then
    ok "scheduler exposes $actual_queues platform queue(s) (>= $expected_queues predeclared) — cold-start race closed"
  else
    warn "scheduler exposes only $actual_queues of $expected_queues expected predeclared queues"
    warn "first Bazel build may still hit FAILED_PRECONDITION — check scheduler logs:"
    warn "  docker compose logs scheduler | grep -i predeclared"
  fi
}

# -----------------------------------------------------------------------------
# Summary.
# -----------------------------------------------------------------------------
summary() {
  # `printf` over `cat <<EOF` so the bold-green banner ANSI escape (\033[…])
  # actually gets interpreted — heredoc would ship it as the literal 4-char
  # sequence, making terminals print `\033[1;32m...` verbatim.
  printf '\n\033[1;32mbb-psmdb-ondemand central node ready.\033[0m\n\n'
  cat <<EOF
  Public (TLS via Let's Encrypt cert for $PUBLIC_HOSTNAME):
    SSH              : ssh -i $SSH_PRIV_KEY root@$PUBLIC_HOSTNAME
    Scheduler admin  : https://$PUBLIC_HOSTNAME:7982/
    bb-browser       : https://$PUBLIC_HOSTNAME:7984/
    Bazel clients    : grpcs://$PUBLIC_HOSTNAME:8981  (TLS terminated by Envoy)

    NB: We always print the DNS hostname here, never the raw \$PUBLIC_IP
    ($PUBLIC_IP). The hostname resolves to the Hetzner Floating IP
    that's pinned to this VM and survives VM redeploys; the primary
    \$PUBLIC_IP can rotate. Browsing https://<floating-ip>:7982/ also
    fails TLS validation because the cert SAN is the hostname, not the
    IP — always use the hostname.

  Private (network 11374636 / psmdb.cd.percona.com):
    Worker gRPC      : grpc://$PRIVATE_IP:8983        (ondemand workers only)

  Localhost (on central host only):
    BuildQueueState  : grpc://127.0.0.1:8984          (scaler consumes this)

  Scaler:
    Mode             : \$SCALER_DRY_RUN in $REMOTE_COMPOSE/.env
                       (fresh install defaults to true = logs-only; redeploys
                        preserve whatever was set before — see bake_env)
    Logs             : ssh root@$PUBLIC_HOSTNAME 'cd $REMOTE_COMPOSE && docker compose logs -f scaler'
    Go live          : edit $REMOTE_COMPOSE/.env → SCALER_DRY_RUN=false
                       then: ssh root@$PUBLIC_HOSTNAME 'cd $REMOTE_COMPOSE && docker compose up -d scaler'

  Debugging a worker (from this central host, over the private network):
    ssh root@$PUBLIC_HOSTNAME
    ssh-worker <worker-private-ip>                    (wrapper at /usr/local/bin/ssh-worker)
    ssh-worker <worker-private-ip> 'cd /opt/buildbarn && docker compose ps'
    (requires the worker was spawned AFTER this deploy — workers created
     under an older central key remain SSH-unreachable from here and need
     idle-reap or explicit 'hcloud server delete' to recycle.)

  Next steps:
    * Manual worker  : scripts/spawn-worker.sh            (for debugging, always works)
    * Autoscaling    : flip SCALER_DRY_RUN=false after watching a dry-run cycle
    * Bazel clients  : --remote_executor=grpcs://$PUBLIC_HOSTNAME:8981
                       (TLS-only since Step 1 of buildbarn-auth-tls-plan.md;
                        plain grpc:// will be rejected at the Envoy listener)
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

  ensure_central_ssh_key
  sync_configs
  compose_up
  smoke
  summary
}

main "$@"
