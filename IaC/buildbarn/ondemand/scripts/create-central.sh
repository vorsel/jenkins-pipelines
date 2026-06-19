#!/usr/bin/env bash
#
# create-central.sh — bring up (or adopt) the bb-psmdb-ondemand central node.
#
# What this script does, in order:
#
#   1. Preflight checks on the operator's laptop (hcloud auth, jq, rsync,
#      local SSH private key, repo layout, Hetzner resource IDs).
#   2. Ensure the server exists in Hetzner Cloud (create if missing) with
#      both SSH keys installed, attached to the project's private network
#      (NETWORK_ID — live value in `INFRASTRUCTURE.md`), on Debian 13.
#   3. Attach the 750 GB xfs volume (ID 105484418) if not already attached.
#   3.5 (optional) Reassign Floating IP $FLOATING_IP_ID to the new server
#       at the API level. This is the cross-project / cross-VM cutover step
#       — when the FIP is assigned to a different (e.g. old) server, that
#       server stops receiving traffic on the FIP from this point onward.
#   4. Install Docker on the host (via get.docker.com) and rsync, if missing.
#   4.5 (optional) Add the Floating IP as an alias on eth0 (`ip addr add`)
#       and persist it via /etc/network/interfaces.d/60-floating-ip.
#       Required because Hetzner FIPs are NOT L2-routed to the VM — the
#       kernel only accepts incoming traffic for IPs configured locally.
#       PUBLIC_IP is flipped from the VM's primary public address to the
#       FIP after this step succeeds.
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
#
# Cross-project warm-CAS migration: export PRESERVE_ENV_FROM=<path-to-old-.env>
# to carry forward BB_PORTAL_DB_PASSWORD and the OIDC/cookie secrets onto a
# fresh central — see the variable's doc-block below for full rationale.

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

# Optional .env backup path. When set, sync_configs() rsyncs this file
# onto the central host as $REMOTE_COMPOSE/.env BEFORE bake_env runs,
# so bake_env's _env_get pulls forward every preserved secret instead
# of regenerating it (BB_PORTAL_DB_PASSWORD, BB_*_OIDC_SECRET,
# BB_*_COOKIE_SEED, GITHUB_OAUTH_*, ...).
#
# Mandatory in cross-project warm-CAS migrations: the portal-db
# Postgres PGDATA travels with the volume, but Postgres' initdb only
# stamps POSTGRES_PASSWORD on a fresh PGDATA — a regenerated password
# would lock bb-portal-backend out of the preserved database. Same
# argument (less catastrophic, but still annoying) for the OIDC/cookie
# secrets: regen would log every operator out of the BB UIs at cutover.
#
# Source the file from the OLD central before tearing it down:
#
#   ssh root@<old-central> 'cat /var/lib/buildbarn/compose/.env' \
#     > "$HOME/.config/psmdb-rbe/old-central.env"
#   chmod 600 "$HOME/.config/psmdb-rbe/old-central.env"
#   export PRESERVE_ENV_FROM="$HOME/.config/psmdb-rbe/old-central.env"
#
# Empty (default) = behave as before: bake_env regenerates everything
# that wasn't already on the new VM's $REMOTE_COMPOSE/.env.
: "${PRESERVE_ENV_FROM:=}"

# Optional Hetzner Floating IP id. When set, the script will:
#
#   1. (re)assign this FIP to $SERVER_NAME via the Hetzner API
#      (ensure_floating_ip — runs after attach_volume);
#   2. configure the FIP as an alias on the VM's eth0 and persist it
#      via /etc/network/interfaces.d/60-floating-ip
#      (configure_floating_ip_on_host — runs after bootstrap_host);
#   3. flip $PUBLIC_IP from the VM's primary public address to the
#      FIP, so every later rssh / rrsync / smoke call uses the
#      stable address.
#
# Step 2 exists because Hetzner FIPs are NOT L2-routed to the assigned
# VM's NIC — the guest kernel only accepts incoming traffic for IPs
# locally configured on an interface. (Earlier versions of this
# script's docs claimed otherwise; that was wrong.)
#
# Idempotent at the API level — three observed states:
#   * already on $SERVER_NAME            → no-op
#   * unassigned                         → assign
#   * assigned to a DIFFERENT server     → unassign + reassign
#                                          (cross-project cutover step:
#                                          old server goes dark on this
#                                          IP, new server takes over)
#
# Empty (default) = leave FIP handling to the operator (manual
# `hcloud floating-ip assign` plus manual `ip addr add` and an
# /etc/network drop-in). Useful when the FIP is shared with another
# stack on the same project, or there's no FIP at all.
: "${FLOATING_IP_ID:=}"

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

  # Dex (Step 3 of the auth plan) needs a GitHub OAuth App registered
  # against the org we want to gate on. The App's Client ID is public,
  # the Client Secret is not — both are required for the GitHub
  # connector to complete the auth-code → access-token exchange.
  #
  # We refuse to default-or-prompt for these because:
  #   * defaulting to "" silently brings up Dex with a broken connector
  #     and the breakage is only visible via /token after the user has
  #     already gone through GitHub's consent screen — terrible UX.
  #   * prompting interactively bakes a 64-char secret into the operator's
  #     shell history if they paste it wrong; let `.bashrc` (or a CI
  #     vault) own the secret and we just read it.
  #
  # Generating the App: see buildbarn-auth-tls-plan.md §6.
  [[ -n "${GITHUB_OAUTH_CLIENT_ID:-}" ]] \
    || die "GITHUB_OAUTH_CLIENT_ID env var is required (export from GitHub OAuth App, see buildbarn-auth-tls-plan.md §6)"
  [[ -n "${GITHUB_OAUTH_CLIENT_SECRET:-}" ]] \
    || die "GITHUB_OAUTH_CLIENT_SECRET env var is required (export from GitHub OAuth App, see buildbarn-auth-tls-plan.md §6)"
  # Loose shape check on the client ID — GitHub's are 20-char hex-ish
  # `Iv1.<16 hex>` for OAuth Apps and `Ov23li<...>` for newer fine-grained
  # apps. Don't fail hard, just warn.
  if ! [[ "$GITHUB_OAUTH_CLIENT_ID" =~ ^(Iv1\.|Ov23li)[A-Za-z0-9]+$ ]]; then
    warn "GITHUB_OAUTH_CLIENT_ID doesn't look like a GitHub OAuth client ID — proceeding anyway"
  fi
  ok "GitHub OAuth client ID captured (${#GITHUB_OAUTH_CLIENT_ID} chars)"
  ok "GitHub OAuth client secret captured (${#GITHUB_OAUTH_CLIENT_SECRET} chars)"

  # Step 5d — coordination string for the GitHub Actions OIDC tier
  # (see dex.yaml `github-actions` connector and envoy.yaml RBAC
  # policies). Operator generates this once per buildfarm with
  # `openssl rand -hex 16` and stores it in their local .env beside
  # the other operator-controlled secrets (HCLOUD_TOKEN, GITHUB_OAUTH_*).
  # We treat it as a soft secret: the script never echoes the value,
  # bake_env writes it to the central .env (mode 0600), and workflow
  # authors reference it via `${{ secrets.PSMDB_RBE_GHA_AUDIENCE }}`
  # so GitHub auto-masks it in workflow logs. The same value MUST
  # also be stored as a GitHub repo/org secret named
  # PSMDB_RBE_GHA_AUDIENCE on every repository whose workflows are
  # expected to drive the buildfarm.
  [[ -n "${PSMDB_RBE_GHA_AUDIENCE:-}" ]] \
    || die "PSMDB_RBE_GHA_AUDIENCE env var is required"
  ok "PSMDB_RBE_GHA_AUDIENCE captured (${#PSMDB_RBE_GHA_AUDIENCE} chars)"

  # Optional .env backup file used to preserve secrets across a fresh-VM
  # deployment (cross-project warm-CAS migration is the canonical use
  # case; see PRESERVE_ENV_FROM doc near the top of this file).
  if [[ -n "$PRESERVE_ENV_FROM" ]]; then
    [[ -r "$PRESERVE_ENV_FROM" ]] \
      || die "PRESERVE_ENV_FROM not readable: $PRESERVE_ENV_FROM"
    # 0600 is what bake_env writes itself; reject anything looser to
    # match the same posture before secrets touch the wire.
    local mode
    mode=$(stat -f '%Lp' "$PRESERVE_ENV_FROM" 2>/dev/null \
        || stat -c '%a'   "$PRESERVE_ENV_FROM")
    [[ "$mode" == "600" ]] \
      || die "PRESERVE_ENV_FROM mode must be 600 (got $mode): chmod 600 $PRESERVE_ENV_FROM"
    # Loose KEY=VALUE shape check — reject obviously corrupt files
    # (e.g. accidentally pointed at $HOME/.bashrc) before we'd ship
    # them onto the central. Empty file is a foot-gun: every secret
    # would still regenerate, defeating the point of pointing at the
    # variable at all.
    [[ -s "$PRESERVE_ENV_FROM" ]] \
      || die "PRESERVE_ENV_FROM is empty: $PRESERVE_ENV_FROM"
    if ! grep -qE '^[A-Z_][A-Z0-9_]*=' "$PRESERVE_ENV_FROM"; then
      die "PRESERVE_ENV_FROM doesn't look like a .env file (no KEY=VALUE lines): $PRESERVE_ENV_FROM"
    fi
    # Sanity-warn if BB_PORTAL_DB_PASSWORD is missing — that's the one
    # secret whose regeneration silently breaks bb-portal-db on a warm
    # CAS migration (Postgres PGDATA on the volume keeps the OLD
    # password, bake_env would mint a NEW one). Don't fail hard:
    # operators recovering from a partial backup may legitimately
    # have a trimmed file.
    if ! grep -qE '^BB_PORTAL_DB_PASSWORD=' "$PRESERVE_ENV_FROM"; then
      warn "PRESERVE_ENV_FROM has no BB_PORTAL_DB_PASSWORD line —"
      warn "bb-portal-db will refuse the freshly-generated password if PGDATA"
      warn "was preserved on the volume. Add the line or expect a portal outage."
    fi
    ok "PRESERVE_ENV_FROM=$PRESERVE_ENV_FROM (mode=$mode, $(wc -l < "$PRESERVE_ENV_FROM") lines)"
  else
    ok "PRESERVE_ENV_FROM not set — bake_env will (re)generate any missing secrets"
  fi

  # The Dex compose file references the ./dex/ subdir — fail early if a
  # half-checked-out repo skipped it.
  [[ -f "$COMPOSE_SRC/dex/dex.yaml" ]] \
    || die "compose/dex/dex.yaml missing — see buildbarn-auth-tls-plan.md §6"

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

  # The Network alone is not enough — scaler.create_server attaches
  # workers to it and needs the network to have at least one Subnet
  # to draw a private IP from. Two failure modes here, both observed:
  #
  #   1. Zero subnets → every spawn fails `no_subnet_available`.
  #      Caught us during the PSMDB-2034 cross-project migration:
  #      runbook Phase 1 listed `network create` but not the
  #      `network add-subnet` follow-up. Hetzner UI also shows the
  #      network as "ready" without a subnet, hiding the gap.
  #
  #   2. Subnets exist but their combined useable IP space is
  #      smaller than max_total_nodes from ondemand-pools.yaml.
  #      Hetzner UI defaults to /28 (16 raw IPs, ~11 useable after
  #      network/gateway/broadcast/internal reservations) which
  #      runs out around 10 workers — invisible until matrix burst,
  #      where it surfaces as a slow trickle of `no_subnet_available`
  #      mid-build. Heuristic: budget ≥1.5x max_total_nodes to leave
  #      headroom for the central + slow-decommission overlap +
  #      Hetzner's per-subnet reservations.
  #
  # Both fail loudly here instead.
  local pools_yaml="$COMPOSE_SRC/config/ondemand-pools.yaml"
  python3 - "$NETWORK_ID" "$pools_yaml" <<'PY'
import json, os, subprocess, sys, yaml

network_id, pools_path = sys.argv[1:3]

# Subnet inventory via hcloud (already verified above).
net = json.loads(subprocess.check_output(
    ["hcloud", "network", "describe", network_id, "-o", "json"]))
subnets = net.get("subnets") or []
if not subnets:
    print(f"  ✗ Hetzner network {network_id} has 0 subnets — "
          f"workers cannot get private IPs.", file=sys.stderr)
    print(f"  Fix: hcloud network add-subnet {network_id} --type cloud "
          f"--network-zone eu-central --ip-range {net['ip_range']}",
          file=sys.stderr)
    sys.exit(1)

# Useable IP estimate per subnet. Hetzner reserves 4 IPs per subnet
# (network, gateway, two more for internal services), so useable =
# 2**(32-prefix) - 4 with a floor of 0.
def useable(ip_range):
    prefix = int(ip_range.split("/")[1])
    return max(0, (1 << (32 - prefix)) - 4)

total = sum(useable(s["ip_range"]) for s in subnets)
breakdown = ", ".join(f"{s['ip_range']}({useable(s['ip_range'])})" for s in subnets)

# Capacity budget = global.max_total_nodes from ondemand-pools.yaml
# (the hard cap the scaler enforces; see scaler.py: cfg.global_.max_total_nodes).
with open(pools_path) as fh:
    pools = yaml.safe_load(fh) or {}
max_total = int((pools.get("global") or {}).get("max_total_nodes", 0))

# 1.5x headroom for central + decommission overlap + Hetzner's
# per-subnet reservation slack we don't model precisely.
budget = max(1, int(max_total * 1.5)) if max_total else 0

print(f"  network ip_range={net['ip_range']}, subnets={len(subnets)} "
      f"[{breakdown}], useable={total}, max_total_nodes={max_total}, "
      f"budget={budget}")

if budget and total < budget:
    print(f"  ✗ subnet capacity {total} < budgeted {budget} "
          f"(=1.5*max_total_nodes). Workers will hit "
          f"`no_subnet_available` during matrix bursts.",
          file=sys.stderr)
    print(f"  Fix: add a non-overlapping second subnet, e.g. for a "
          f"/24 network (256 IPs total) and an existing /28:",
          file=sys.stderr)
    print(f"    hcloud network add-subnet {network_id} --type cloud "
          f"--network-zone eu-central --ip-range "
          f"{net['ip_range'].split('/')[0].rsplit('.', 1)[0]}.128/25",
          file=sys.stderr)
    sys.exit(1)
PY
  ok "Hetzner network capacity OK for current pools.yaml budget"

  # Optional Floating IP — caller opted in to auto-assign by setting
  # $FLOATING_IP_ID. Confirm the resource exists in this project before
  # going any further; cheap, and saves a confusing failure deep into
  # the run when ensure_floating_ip can't describe it.
  if [[ -n "$FLOATING_IP_ID" ]]; then
    local fip_json fip_address
    fip_json=$(hcloud floating-ip describe "$FLOATING_IP_ID" -o json 2>/dev/null) \
      || die "Floating IP $FLOATING_IP_ID not found in project — clear FLOATING_IP_ID or fix the id"
    fip_address=$(jq -r '.ip' <<<"$fip_json")
    [[ -n "$fip_address" && "$fip_address" != "null" ]] \
      || die "Floating IP $FLOATING_IP_ID has no usable address"
    ok "Floating IP ${FLOATING_IP_ID} (${fip_address}) present"
  else
    ok "FLOATING_IP_ID not set — skipping FIP auto-assign"
  fi

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
# Set by configure_floating_ip_on_host once $PUBLIC_IP is flipped to the FIP —
# kept around so summary() can still print the VM's primary address as a
# fallback SSH endpoint (useful if FIP alias breaks and the operator needs to
# log in directly to debug).
PUBLIC_IP_PRIMARY=""

# Stashed by ensure_floating_ip and consumed by configure_floating_ip_on_host.
# Holds the FIP literal (e.g. "95.217.242.120") so we don't have to re-query
# the Hetzner API just to read what we already saw at API-assign time.
FLOATING_IP_ADDRESS=""

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
# Floating IP — assign $FLOATING_IP_ID to $SERVER_NAME via the Hetzner API.
#
# Three observed states map to three behaviours (see top-of-file
# FLOATING_IP_ID doc-block for context):
#
#   already on $SERVER_NAME       → no-op
#   unassigned                    → assign
#   assigned to a DIFFERENT server → unassign + reassign (cutover)
#
# IMPORTANT: assigning the FIP at the API level alone is NOT enough to
# make incoming traffic to the FIP reach the VM. Contrary to common
# misconception, Hetzner FIPs are NOT routed at L2 to the assigned
# server's NIC — the kernel rejects packets addressed to an IP that
# isn't configured on any local interface ("Destination Host
# Unreachable"). The matching guest-OS configuration step
# (`ip addr add <FIP>/32 dev eth0` + a persistent ifupdown alias) is
# done in configure_floating_ip_on_host() AFTER bootstrap_host has run.
#
# Hence this function intentionally does NOT touch $PUBLIC_IP. SSH /
# rsync continue to operate against the VM's primary public IP until
# the alias is in place; only then does configure_floating_ip_on_host
# flip $PUBLIC_IP to the FIP.
# -----------------------------------------------------------------------------
ensure_floating_ip() {
  if [[ -z "$FLOATING_IP_ID" ]]; then
    return 0
  fi
  step "Floating IP"

  local fip_json fip_address fip_server_id our_server_id their_name
  fip_json=$(hcloud floating-ip describe "$FLOATING_IP_ID" -o json) \
    || die "could not describe Floating IP $FLOATING_IP_ID"
  fip_address=$(jq -r '.ip' <<<"$fip_json")
  fip_server_id=$(jq -r '.server // empty' <<<"$fip_json")
  our_server_id=$(hcloud server describe "$SERVER_NAME" -o json | jq -r '.id')

  if [[ -z "$fip_server_id" || "$fip_server_id" == "null" ]]; then
    log "Floating IP $fip_address (id $FLOATING_IP_ID) currently unassigned — attaching to $SERVER_NAME"
    hcloud floating-ip assign "$FLOATING_IP_ID" "$SERVER_NAME"
  elif [[ "$fip_server_id" == "$our_server_id" ]]; then
    ok "Floating IP $fip_address already on $SERVER_NAME"
  else
    # Cross-project / cross-VM cutover step. Unassigning is a one-call
    # API mutation; the previous owner stops receiving traffic on this
    # IP immediately. We log loudly because this is the irreversible
    # bit of the migration — old central is dark on $fip_address from
    # this point until somebody manually reassigns.
    their_name=$(hcloud server describe "$fip_server_id" -o json 2>/dev/null \
                 | jq -r '.name // "(unknown)"')
    warn "Floating IP $fip_address currently assigned to $their_name (id $fip_server_id) —"
    warn "this is the cutover step: unassigning, then reassigning to $SERVER_NAME."
    warn "$their_name will be unreachable on $fip_address from this point."
    hcloud floating-ip unassign "$FLOATING_IP_ID"
    hcloud floating-ip assign   "$FLOATING_IP_ID" "$SERVER_NAME"
  fi

  ok "Floating IP $fip_address → $SERVER_NAME (API-level)"
  ok "OS-level alias will be configured by configure_floating_ip_on_host after bootstrap_host"

  # Stash the FIP address for the OS-config step. We deliberately do
  # NOT touch $PUBLIC_IP here — see the function-header comment.
  FLOATING_IP_ADDRESS="$fip_address"
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

# Disable Hetzner's regional mirror before ANY apt-get runs. mirror.hetzner.com
# periodically serves mid-sync indexes — 404 / "File has unexpected size ...
# Mirror sync in progress?" on trixie-backports — which makes `apt-get update`
# exit non-zero and, under the `set -e` above, aborts this whole step. The
# stock Hetzner Debian 13 image already ships deb.debian.org in debian.sources,
# so we disable the Hetzner drop-ins rather than rewrite them (rewriting
# duplicates debian.sources → "configured multiple times" flood). Guard on
# debian.sources so we never strip all sources; idempotent. NB: re-running this
# script also cleans up a host where the mirror files were previously rewritten
# (disable-by-filename catches them regardless of their current URL).
if [ -s /etc/apt/sources.list.d/debian.sources ]; then
  for f in /etc/apt/sources.list.d/*hetzner*.sources /etc/apt/sources.list.d/*hetzner*.list; do
    [ -e "$f" ] || continue
    mv -f "$f" "$f.disabled"
  done
fi

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

# Distro packages.
#
# Build-time / scripted dependencies:
#   * rsync       — push configs from the operator's laptop.
#   * xfsprogs    — wipe-attach paths through mkfs.xfs the data volume.
#   * jq          — operator convenience + a few inline pipelines below.
#   * python3-yaml — bake_env()'s predeclared.libsonnet generator
#                    (parses ondemand-pools.yaml → jsonnet-compatible
#                    JSON) and the in-place pools.yaml rewriter.
#
# Operational diagnostics (cheap to install, expensive to be without
# at 02:00 when something's on fire):
#   * dnsutils    — dig/nslookup for DNS troubleshooting (bb-psmdb.ddns.net,
#                   Hetzner endpoint resolution).
#   * iotop, htop — process-level CPU + IO inspection.
#   * tcpdump     — TCP/TLS handshake captures (debugged the PSMDB-2034
#                   SslHandshakeTimeout wave with this).
#   * lsof        — "what's holding this fd / port / mountpoint" — the
#                   reason `umount /var/lib/buildbarn` failed during
#                   the PSMDB-2034 drain on the OLD central.
#   * vim, less   — interactive editing/paging on the central; vim-tiny
#                   ships by default but the full vim is friendlier.
#   * mtr-tiny    — single-pane ICMP/UDP path quality (workers ↔ central
#                   intra-AZ latency spot-checks).
apt-get update
apt-get install -y \
    rsync jq xfsprogs python3-yaml \
    dnsutils iotop htop tcpdump lsof vim less mtr-tiny

systemctl enable --now docker

# CLI tools NOT in Debian repos. Both are static Go binaries shipped as
# tarballs from upstream GitHub releases; we drop them in /usr/local/bin
# (not managed by apt — fine, they self-update via re-running this
# script after `rm /usr/local/bin/<tool>`).
#
#   * hcloud      — Hetzner Cloud CLI. Useful at the host level for
#                   ad-hoc resolution of SSH key / network / server
#                   IDs without spelunking the REST API by hand. The
#                   PSMDB-2034 hotfix script had to fall back to
#                   `curl + python3 -c json` because hcloud was missing
#                   here — install it once and that goes away. The
#                   asset name (`hcloud-linux-<arch>.tar.gz`) does NOT
#                   include the version, so the GitHub `latest/download`
#                   redirect is sufficient — no version pin needed.
#   * grpcurl     — gRPC equivalent of curl. Indispensable for poking
#                   bb-scheduler / bb-storage / Envoy without a Bazel
#                   client (e.g. `grpcurl -insecure $HOST:7982
#                   list buildbarn.buildqueuestate.BuildQueueState`).
#                   Asset name embeds the version, so we pin and bump
#                   manually — bump = single line below + redeploy.
ARCH=$(dpkg --print-architecture)   # amd64 | arm64

# grpcurl tarballs follow a different arch convention than `dpkg
# --print-architecture` reports — upstream publishes:
#   * grpcurl_<v>_linux_x86_64.tar.gz   (NOT linux_amd64.tar.gz)
#   * grpcurl_<v>_linux_arm64.tar.gz
# while the .deb / .rpm assets DO use the amd64/arm64 spelling. Confused
# us once on a fresh bake — the script tried `linux_amd64.tar.gz` and
# 404'd. Map dpkg arch → grpcurl tarball arch explicitly.
case "$ARCH" in
  amd64) GRPCURL_ARCH=x86_64 ;;
  arm64) GRPCURL_ARCH=arm64  ;;
  *)     echo "FATAL: unsupported dpkg arch '$ARCH' (expected amd64|arm64)" >&2; exit 1 ;;
esac

if ! command -v hcloud >/dev/null 2>&1; then
  echo "  installing hcloud CLI ($ARCH) …"
  curl -fsSL "https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-${ARCH}.tar.gz" \
    | tar -xzf - -C /usr/local/bin hcloud
  chmod 0755 /usr/local/bin/hcloud
  echo "  ✓ hcloud installed: $(hcloud version 2>&1 | head -n1)"
else
  echo "  ✓ hcloud already present: $(hcloud version 2>&1 | head -n1)"
fi

GRPCURL_VERSION=1.9.3
if ! command -v grpcurl >/dev/null 2>&1; then
  echo "  installing grpcurl v$GRPCURL_VERSION ($GRPCURL_ARCH) …"
  curl -fsSL "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_${GRPCURL_ARCH}.tar.gz" \
    | tar -xzf - -C /usr/local/bin grpcurl
  chmod 0755 /usr/local/bin/grpcurl
  echo "  ✓ grpcurl installed: $(grpcurl --version 2>&1)"
else
  echo "  ✓ grpcurl already present: $(grpcurl --version 2>&1)"
fi

# PSMDB-2034: kernel-level burst tolerance for TLS handshakes.
#
# Envoy's grpc_listener / bes_grpc_listener both set tcp_backlog_size:
# 4096 (envoy.yaml), but the kernel caps any listen(2) backlog at the
# minimum of (tcp_backlog_size, net.core.somaxconn) — defaults differ
# by Debian release; on Debian 13 net.core.somaxconn ships as 4096
# but historically can drop back to 128 on certain images. We pin
# both somaxconn and the SYN backlog explicitly so the listener
# config takes the shape it asks for under matrix burst load.
#
# Drop-in is a single file (NOT edits to /etc/sysctl.conf, which can
# vary across cloud-init renderings); idempotent on re-runs.
SYSCTL=/etc/sysctl.d/99-bb-psmdb-tcp-burst.conf
if [[ ! -f "$SYSCTL" ]]; then
  cat > "$SYSCTL" <<EOF
# Managed by create-central.sh::bootstrap_host. Sized for matrix-load
# Bazel bursts (~11 stages × ~72 jobs × 3 channels = ~2300 simultaneous
# TCP SYNs into Envoy on :8981 / :1985).
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
# Reduce TIME_WAIT churn — gRPC clients open and close streams faster
# than tcp_fin_timeout's default 60s reclaims them, so without these
# tuned values the source-port pool can drain on the central side
# during long matrix runs.
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
EOF
  sysctl --system >/dev/null
  echo "  ✓ wrote $SYSCTL and reloaded sysctl"
else
  # Already present from a previous run — re-apply in case sysctl was
  # reverted by a kernel upgrade or manual `sysctl -w` session.
  sysctl --system >/dev/null
  echo "  ✓ $SYSCTL already present (re-applied)"
fi
REMOTE
  ok "host packaged prepared"
}

# -----------------------------------------------------------------------------
# Configure the Floating IP as an alias on the host's primary NIC.
#
# Runs AFTER bootstrap_host (so SSH is up via primary IP, ifupdown is
# present, and we can persist the alias). Idempotent:
#
#   * `ip addr add <FIP>/32 dev eth0` returns 2 if the alias already
#     exists — caught with `|| true` and logged at debug level.
#   * `/etc/network/interfaces.d/60-floating-ip` is rewritten every
#     run; contents are deterministic so re-runs are no-ops as far as
#     ifupdown is concerned.
#
# Only after the alias is in place do we flip $PUBLIC_IP to the FIP
# and re-prime known_hosts so subsequent rssh / rrsync / smoke calls
# go through the stable address.
#
# Skipped entirely when $FLOATING_IP_ID is empty (no opt-in).
# -----------------------------------------------------------------------------
configure_floating_ip_on_host() {
  if [[ -z "$FLOATING_IP_ID" ]]; then
    return 0
  fi
  [[ -n "$FLOATING_IP_ADDRESS" ]] \
    || die "configure_floating_ip_on_host: FLOATING_IP_ADDRESS is empty (ensure_floating_ip didn't run?)"
  step "Floating IP — host alias"

  # Add the alias inside a here-doc so a single rssh round-trip handles
  # both the immediate `ip addr add` and the persistent /etc/network
  # drop-in. Using ifupdown's interfaces.d/ over systemd-networkd /
  # netplan because Hetzner's Debian 13 cloud image ships with ifupdown
  # configuring eth0 — anything else would be a parallel network
  # management plane fighting over the same interface.
  rssh "FLOATING_IP_ADDRESS='$FLOATING_IP_ADDRESS' bash -se" <<'REMOTE'
set -euo pipefail

# Immediate (RAM-only) — `ip addr add` returns 2 when the address is
# already there; treat that as success.
if ! ip addr show eth0 | grep -q "inet $FLOATING_IP_ADDRESS"; then
  ip addr add "${FLOATING_IP_ADDRESS}/32" dev eth0
  echo "  ✓ ip addr add ${FLOATING_IP_ADDRESS}/32 dev eth0"
else
  echo "  ✓ alias ${FLOATING_IP_ADDRESS}/32 already on eth0"
fi

# Persistent — drop a small ifupdown stanza so the alias re-attaches on
# reboot. Mode 0644 (no secrets here, just an IP literal). The double
# colon in the iface name (`eth0:fip0`) is the legacy ifupdown alias
# syntax — also recognised by the `ifquery` smoke check below.
mkdir -p /etc/network/interfaces.d
cat > /etc/network/interfaces.d/60-floating-ip <<EOF
# Hetzner Floating IP $FLOATING_IP_ADDRESS — managed by create-central.sh.
# Required because Hetzner FIPs are not L2-routed to the assigned VM's
# NIC; the kernel only accepts incoming traffic for IPs configured
# locally. See INFRASTRUCTURE.md §9 for the full rationale.
auto eth0:fip0
iface eth0:fip0 inet static
    address $FLOATING_IP_ADDRESS
    netmask 255.255.255.255
EOF
chmod 644 /etc/network/interfaces.d/60-floating-ip
echo "  ✓ persisted /etc/network/interfaces.d/60-floating-ip"

# Sanity: confirm ifupdown can parse the file and the alias is up.
# `ifquery` prints the parsed config; failure here is a typo /
# unmatched physical iface and we'd rather find that now than at
# the next reboot.
if command -v ifquery >/dev/null 2>&1; then
  ifquery eth0:fip0 >/dev/null \
    && echo "  ✓ ifquery eth0:fip0 OK"
fi
REMOTE
  ok "Floating IP $FLOATING_IP_ADDRESS aliased on eth0 (immediate + persistent)"

  # Now flip PUBLIC_IP to the FIP. Save the primary first for the
  # summary banner. From this point on every rssh / rrsync / smoke
  # call goes via the FIP — so we also re-prime known_hosts so the
  # first SSH on the new endpoint doesn't hang on host-key prompt.
  PUBLIC_IP_PRIMARY="$PUBLIC_IP"
  PUBLIC_IP="$FLOATING_IP_ADDRESS"
  ok "PUBLIC_IP overridden: $PUBLIC_IP_PRIMARY → $PUBLIC_IP (FIP)"

  # Prime known_hosts for the FIP. We accept-new the host key the
  # same way wait_for_ssh does for the primary; same VM, same key,
  # so this just registers a second hostname for it. ssh-keygen -R
  # first to guarantee no stale FIP entry from a previous failed run
  # (e.g. an aborted run where someone Ctrl-C'd).
  ssh-keygen -R "$PUBLIC_IP" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1 || true
  ssh -i "$SSH_PRIV_KEY" \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      "root@$PUBLIC_IP" true \
    || die "FIP $PUBLIC_IP not reachable over SSH after alias config — check 'ip addr show eth0' on the VM and /etc/network/interfaces.d/60-floating-ip"
  ok "FIP-side SSH primed (known_hosts updated)"
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
  ok "ssh-worker wrapper installed — run e.g. 'ssh-worker <worker-private-ip> docker compose ps' on central"
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

# Dex SQLite DB lives here. The dex container runs as UID:GID 1001:1001
# (see Dockerfile in dexidp/dex@v2.41+: USER 1001:1001), so the host
# directory has to be owned by 1001:1001 or sqlite3 fails on first
# write with EACCES. We chown unconditionally — cheap, idempotent, and
# protects against anyone manually `mkdir`-ing this path as root before
# first run. Mode 0700: the file holds JWT signing-key material and
# refresh tokens; nothing else on the host needs to read it.
mkdir -p "$REMOTE_BASE/dex"
chown 1001:1001 "$REMOTE_BASE/dex"
chmod 0700      "$REMOTE_BASE/dex"

# bb-portal Postgres PGDATA. The PDP image (`percona/percona-distribution-
# postgresql:17.x`) runs Postgres as UID 26 — RHEL UBI's `postgres`
# user, baked into the Dockerfile's `USER 26` line (see
# github.com/percona/percona-docker/percona-distribution-postgresql-17/
# Dockerfile). The bind-mount at /data/db must be owned by 26:26
# BEFORE the container's entrypoint runs `initdb` on first boot,
# otherwise initdb fails with `Permission denied`. chown is recursive
# because on re-run we may inherit existing PGDATA contents.
# Mode 0700 matches the perms initdb itself sets after success.
mkdir -p "$REMOTE_BASE/portal-db"
chown -R 26:26 "$REMOTE_BASE/portal-db"
chmod 0700     "$REMOTE_BASE/portal-db"
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

  # 3.5) Optional: pre-seed remote .env from a local backup so bake_env's
  #      _env_get pulls forward existing secrets instead of regenerating
  #      them. Mandatory in cross-project warm-CAS migrations (the
  #      portal-db Postgres PGDATA travels with the volume but Postgres
  #      doesn't re-stamp POSTGRES_PASSWORD on existing PGDATA — see
  #      PRESERVE_ENV_FROM doc near the top of this file).
  #
  #      Runs AFTER the rsync above (step 3 ships compose/ with
  #      --exclude=.env, so .env on the central is whatever was there
  #      before — empty on a fresh VM, populated on a re-run) and
  #      BEFORE the bake_env heredoc (step 4) which reads .env via
  #      _env_get. End result: bake_env sees our seed file and
  #      preserves every key it carries.
  if [[ -n "$PRESERVE_ENV_FROM" ]]; then
    log "pre-seed remote .env from $PRESERVE_ENV_FROM"
    # rrsync = rsync -a --delete; -a includes -p (preserve perms). Local
    # file is already 0600 (preflight verifies) so the remote inherits the
    # same mode without any --chmod flag — handy because Apple's stock
    # macOS rsync (2.6.9) doesn't recognise the `--chmod=F<octal>` short
    # form at all and would die with "invalid argument" here.
    #
    # Belt-and-braces chmod via ssh right after, so a future change to
    # the local file's perms (or a copy through a renderer that drops
    # them) doesn't leak HCLOUD_TOKEN/OAuth secrets to a 0644 file.
    rrsync \
      "$PRESERVE_ENV_FROM" \
      "root@$PUBLIC_IP:$REMOTE_COMPOSE/.env"
    rssh "chmod 600 '$REMOTE_COMPOSE/.env'"
    ok "remote .env seeded (mode 0600) — bake_env will preserve secrets via _env_get"
  fi

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
    "SSH_KEY_IDS='$SSH_KEY_IDS'" \
    "NETWORK_ID='$NETWORK_ID'" \
    "GITHUB_OAUTH_CLIENT_ID='$GITHUB_OAUTH_CLIENT_ID'" \
    "GITHUB_OAUTH_CLIENT_SECRET='$GITHUB_OAUTH_CLIENT_SECRET'" \
    "PSMDB_RBE_GHA_AUDIENCE='$PSMDB_RBE_GHA_AUDIENCE'" \
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

# OIDC client secrets for the bb-browser / bb-scheduler static clients
# in dex.yaml. We generate these once and PRESERVE them across re-runs:
# rotating them silently would invalidate every active operator session
# (refresh tokens stop validating against Dex) and force a wave of
# re-logins on the next deploy — surprise we want to avoid. Operators
# can rotate explicitly by `sed -i '/^BB_BROWSER_OIDC_SECRET=/d' .env`
# before re-running. 32 bytes hex = 256 bits of entropy, plenty for an
# HMAC.
PREV_BROWSER_SECRET=$(_env_get BB_BROWSER_OIDC_SECRET)
PREV_SCHED_SECRET=$(_env_get BB_SCHED_OIDC_SECRET)
BB_BROWSER_OIDC_SECRET="${PREV_BROWSER_SECRET:-$(openssl rand -hex 32)}"
BB_SCHED_OIDC_SECRET="${PREV_SCHED_SECRET:-$(openssl rand -hex 32)}"

# Cookie seeds — additional entropy mixed into the AES-GCM key that BB
# uses to encrypt session cookies (see bb-storage authenticator.go,
# specifically: cookieSeedHash = sha256(cookieSeed || marshalled OIDC
# config), first 128 bits = cookie name, last 128 bits = AES key).
# Generated once per service, preserved across re-runs for the same
# reason as the OIDC client secrets above: rotating the seed
# invalidates every live operator session and forces a wave of GitHub
# logins on the next deploy. To deliberately rotate, blank the value
# in .env before re-running.
PREV_BROWSER_COOKIE=$(_env_get BB_BROWSER_COOKIE_SEED)
PREV_SCHED_COOKIE=$(_env_get BB_SCHED_COOKIE_SEED)
BB_BROWSER_COOKIE_SEED="${PREV_BROWSER_COOKIE:-$(openssl rand -hex 32)}"
BB_SCHED_COOKIE_SEED="${PREV_SCHED_COOKIE:-$(openssl rand -hex 32)}"

# bb-portal — third Buildbarn UI delegating login to Dex. Same
# generation + persistence rules as the bb-browser / bb-scheduler
# pair above (silent rotation kicks every operator out, so we pull
# forward across re-runs). The DB password is generated the same
# way and lives in the same .env bucket — bb-portal-backend reads
# it as POSTGRES_PASSWORD-equivalent-via-pgx-connection-string and
# bb-portal-db consumes it via POSTGRES_PASSWORD env. NOT a human-
# typeable password — only ever read by containers on this host.
PREV_PORTAL_OIDC=$(_env_get BB_PORTAL_OIDC_SECRET)
PREV_PORTAL_COOKIE=$(_env_get BB_PORTAL_COOKIE_SEED)
PREV_PORTAL_DB_PWD=$(_env_get BB_PORTAL_DB_PASSWORD)
BB_PORTAL_OIDC_SECRET="${PREV_PORTAL_OIDC:-$(openssl rand -hex 32)}"
BB_PORTAL_COOKIE_SEED="${PREV_PORTAL_COOKIE:-$(openssl rand -hex 32)}"
BB_PORTAL_DB_PASSWORD="${PREV_PORTAL_DB_PWD:-$(openssl rand -hex 32)}"

cat > "$REMOTE_COMPOSE/.env" <<EOF
# Generated by create-central.sh — edit by hand if you know what you're doing.
# Tags below mirror the currently-working barn-psmdb control plane.
BB_STORAGE_TAG=20260326T151518Z-d0c6f26
BB_SCHEDULER_TAG=20260326T163248Z-e6ab874
BB_BROWSER_TAG=20260319T101727Z-1731858
# bb-portal (build observability — see buildbarn-portal-plan.md).
# Single tag covers BOTH the Go backend and the Next.js frontend
# images (they're published from the same commit upstream).
BB_PORTAL_TAG=20260420T074351Z-91f89aa
# Percona Distribution for PostgreSQL 17 line, pinned to a specific
# minor on purpose — see plan §"Scope → 2".
BB_PORTAL_PDP_TAG=17.9
ENVOY_IMAGE_TAG=v1.31-latest
# Dex (OIDC IdP). Pinned major.minor — bump after smoke-testing.
# v2.41.x is the line we built dex.yaml against.
DEX_IMAGE_TAG=v2.41.1
# Public hostname — referenced by bb-portal-frontend's NEXT_PUBLIC_*
# URLs (UI deep-links would render with the empty string otherwise).
PUBLIC_HOSTNAME=$PUBLIC_HOSTNAME
PRIVATE_IP=$PRIVATE_IP
HCLOUD_TOKEN=$HCLOUD_TOKEN
# OIDC — Dex GitHub connector (forwarded from the operator's shell at
# bake time). These two are the GitHub OAuth App credentials and are
# the only secrets here that aren't auto-rotated; if you rotate the
# App on github.com, re-export and re-run this script.
GITHUB_OAUTH_CLIENT_ID=$GITHUB_OAUTH_CLIENT_ID
GITHUB_OAUTH_CLIENT_SECRET=$GITHUB_OAUTH_CLIENT_SECRET
# Step 5d — GitHub Actions OIDC audience coordination string. Read by
# Dex's github-actions connector via DEX_EXPAND_ENV.
PSMDB_RBE_GHA_AUDIENCE=$PSMDB_RBE_GHA_AUDIENCE
# OIDC — per-Buildbarn-service client secrets. Generated once on first
# run and pulled forward on every re-run (see PREV_*_SECRET above).
BB_BROWSER_OIDC_SECRET=$BB_BROWSER_OIDC_SECRET
BB_SCHED_OIDC_SECRET=$BB_SCHED_OIDC_SECRET
# OIDC — per-service session-cookie seeds. Same persistence rules.
BB_BROWSER_COOKIE_SEED=$BB_BROWSER_COOKIE_SEED
BB_SCHED_COOKIE_SEED=$BB_SCHED_COOKIE_SEED
# bb-portal — OIDC client secret + session cookie seed (same shape
# and persistence rules as the bb-browser / bb-scheduler pair above).
BB_PORTAL_OIDC_SECRET=$BB_PORTAL_OIDC_SECRET
BB_PORTAL_COOKIE_SEED=$BB_PORTAL_COOKIE_SEED
# bb-portal — Postgres superuser password. Used by bb-portal-db
# (POSTGRES_PASSWORD env on the container) and embedded into the
# rendered bb-portal.jsonnet's connectionString at bake time.
BB_PORTAL_DB_PASSWORD=$BB_PORTAL_DB_PASSWORD
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
chmod 600 "$REMOTE_COMPOSE/.env"   # token + OIDC secrets inside; keep off `ls -l` casual reads.

# Replace placeholders in the jsonnet library:
#
#   __BB_PUBLIC_URL__       → https://<host>:7984 (bb-browser)
#   __BB_SCHEDULER_URL__    → https://<host>:7982 (bb-scheduler admin UI)
#   __BB_OIDC_ISSUER__      → https://<host>:5556 (Dex), MUST exactly
#                             match `issuer:` in compose/dex/dex.yaml
#   __BB_BROWSER_OIDC_CLIENT_SECRET__ / __BB_SCHED_OIDC_CLIENT_SECRET__
#                           → per-service OIDC secrets generated above
#   __BB_BROWSER_COOKIE_SEED__ / __BB_SCHED_COOKIE_SEED__
#                           → per-service session-cookie entropy
#
# All replacements happen on the BAKED COPIES under $REMOTE_COMPOSE/config/
# (rsync'd from the laptop a few steps earlier). The repo copies retain
# the placeholder tokens so committing back to git doesn't leak secrets.
#
# `|` chosen as sed delimiter to avoid escaping the URL slashes.
# The OIDC secret/seed values are 64-char hex (no shell metacharacters
# that need escaping inside double-quoted sed scripts), but we still
# pin the delimiter to `|` for consistency.
sed -i "s|__BB_PUBLIC_URL__|https://$PUBLIC_HOSTNAME:7984|g" \
  "$REMOTE_COMPOSE/config/common.libsonnet"
sed -i "s|__BB_SCHEDULER_URL__|https://$PUBLIC_HOSTNAME:7982|g" \
  "$REMOTE_COMPOSE/config/common.libsonnet"
sed -i "s|__BB_PORTAL_URL__|https://$PUBLIC_HOSTNAME:7986|g" \
  "$REMOTE_COMPOSE/config/common.libsonnet"
sed -i "s|__BB_OIDC_ISSUER__|https://$PUBLIC_HOSTNAME:5556|g" \
  "$REMOTE_COMPOSE/config/common.libsonnet"
sed -i "s|__BB_BROWSER_OIDC_CLIENT_SECRET__|$BB_BROWSER_OIDC_SECRET|g" \
  "$REMOTE_COMPOSE/config/browser.jsonnet"
sed -i "s|__BB_BROWSER_COOKIE_SEED__|$BB_BROWSER_COOKIE_SEED|g" \
  "$REMOTE_COMPOSE/config/browser.jsonnet"
sed -i "s|__BB_SCHED_OIDC_CLIENT_SECRET__|$BB_SCHED_OIDC_SECRET|g" \
  "$REMOTE_COMPOSE/config/scheduler.jsonnet"
sed -i "s|__BB_SCHED_COOKIE_SEED__|$BB_SCHED_COOKIE_SEED|g" \
  "$REMOTE_COMPOSE/config/scheduler.jsonnet"
sed -i "s|__BB_PORTAL_OIDC_CLIENT_SECRET__|$BB_PORTAL_OIDC_SECRET|g" \
  "$REMOTE_COMPOSE/config/bb-portal.jsonnet"
sed -i "s|__BB_PORTAL_COOKIE_SEED__|$BB_PORTAL_COOKIE_SEED|g" \
  "$REMOTE_COMPOSE/config/bb-portal.jsonnet"
sed -i "s|__BB_PORTAL_DB_PASSWORD__|$BB_PORTAL_DB_PASSWORD|g" \
  "$REMOTE_COMPOSE/config/bb-portal.jsonnet"

# Belt-and-braces: refuse to deploy if any placeholder survived the
# sed pass — a leftover token would surface only as a runtime BB
# startup error like "OIDCAuthenticationPolicy.client_secret is
# empty" or worse, "iss claim mismatch" on first login. Catching it
# here turns "build fails 30s into login" into "deploy fails before
# we even start the containers".
if grep -RIl '__BB_[A-Z_]*__' "$REMOTE_COMPOSE/config/"; then
  echo "ERROR: unresolved __BB_*__ placeholders in baked configs above" >&2
  echo "Fix the corresponding sed line in scripts/create-central.sh." >&2
  exit 1
fi

# Patch ondemand-pools.yaml at bake time:
#
#   * scheduler_public_url / scheduler_private_ip — repo copy ships with
#     `null` placeholders so a clean `git checkout` doesn't carry stale
#     IPs; fill them with the current central's public+private now.
#   * hcloud_ssh_key_ids — HARD-OVERWRITE with the operator's $SSH_KEY_IDS
#     (from cluster.env) plus the central's own key resolved by
#     ensure_central_ssh_key(). Repo defaults are intentionally stale
#     example IDs — they exist for documentation only and any "append"
#     behaviour would silently mix in IDs from whatever project the
#     example was last sourced against. PSMDB-2034 cross-project
#     migration regression: scaler logged "SSH key not found" for every
#     spawn because old-project ids 24333399/111196538 (committed in
#     repo) leaked through to the new project's bake. Overwrite cleanly.
#   * hcloud_network_id — same story. Repo default is the OLD project's
#     network id, useless in any other project. Overwrite from
#     $NETWORK_ID (cluster.env).
#
# We use yaml round-trip here instead of line-anchored sed because list
# mutation is awkward in sed and we already need python3-yaml on this
# host for the predeclared.libsonnet generator below. Comments in the
# baked copy are lost by safe_dump — acceptable; the operator reads the
# repo file for docs, the baked copy is an artifact consumed by the
# scaler which only cares about structure.
POOLS="$REMOTE_COMPOSE/config/ondemand-pools.yaml"
python3 - "$POOLS" "https://$PUBLIC_HOSTNAME:7982" "$PRIVATE_IP" "$CENTRAL_SSH_KEY_ID" "$SSH_KEY_IDS" "$NETWORK_ID" <<'PY'
import sys, yaml
path, pub_url, priv_ip, central_key_str, ssh_key_ids_str, network_id_str = sys.argv[1:7]
central_key_id = int(central_key_str)
# $SSH_KEY_IDS is whitespace-separated in cluster.env (matches the
# script-level default at the top of create-central.sh). Empty string =
# no operator keys (only the central's own key gets injected — workers
# would still be reachable from the central, just not from operator
# laptops; sensible default for headless CI).
operator_key_ids = [int(x) for x in ssh_key_ids_str.split() if x.strip()]
network_id = int(network_id_str)

with open(path) as fh:
    doc = yaml.safe_load(fh) or {}
g = doc.setdefault("global", {})
g["scheduler_public_url"] = pub_url
g["scheduler_private_ip"] = priv_ip
g["hcloud_network_id"] = network_id

# Hard-overwrite the SSH key list. Order: operator keys first
# (so the laptop can SSH in for debugging without depending on the
# central as a jump host), then central's own key (used by the
# central → worker control plane). Dedup while preserving order so
# a re-run doesn't grow the list past the few entries we actually
# want.
seen = set()
all_keys = []
for kid in operator_key_ids + [central_key_id]:
    if kid not in seen:
        seen.add(kid)
        all_keys.append(kid)
g["hcloud_ssh_key_ids"] = all_keys

with open(path, "w") as fh:
    yaml.safe_dump(doc, fh, default_flow_style=False, sort_keys=False)
print(f"  ✓ ondemand-pools.yaml patched: public_url={pub_url}, private_ip={priv_ip}, network_id={network_id}, hcloud_ssh_key_ids={all_keys}")
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

# Config-driven services bind-mount files from ./config/* (or ./scaler/*).
# `docker compose up -d` only compares the *compose definition* (image
# tag, env, volumes), NOT the *content* of bind-mounted files — so an
# edit to e.g. browser.jsonnet, scheduler.jsonnet or common.libsonnet
# would silently fail to take effect on a redeploy while the container
# reports "running".
#
# Bit us twice already:
#   * predeclaredPlatformQueues rollout — scheduler kept stale config,
#     first cold-start Bazel hit FAILED_PRECONDITION because the
#     predeclared queue was never actually registered.
#   * Step 4 OIDC rollout (PSMDB-2040) — bb-browser kept allow{} from
#     a previous deploy because we only restarted scheduler+scaler;
#     scheduler picked up the new OIDC config but bb-browser silently
#     served the old plaintext UI for hours.
#
# Solution: restart EVERY service that mounts ./config/. The file
# placeholder substitution in bake_env touches common.libsonnet
# (which is `import`-ed by all of them), so any of them could in
# principle observe stale values. Also restart `scaler` whose own
# config dir gets re-rsynced from ./scaler/. Cheap on this host
# (~2-5s per service, in parallel).
#
# `reapi-proxy` stays out of this list — it's a Go binary built from
# Dockerfile, no bind-mount config. Anything else with a bind-mounted
# config gets restarted.
#
# `envoy-proxy` IS in the list: envoy.yaml is bind-mounted from
# /var/lib/buildbarn/reapi-proxy/envoy.yaml (the path is misleading —
# the file is the envoy proxy's config, not reapi-proxy's). Bit us
# briefly during Step 5 testing where edits to the jwt_authn filter
# weren't picked up until we explicitly restarted.
#
# `dex` MUST be in the list: dex.yaml is bind-mounted, and even though
# bake_env doesn't template it (no __BB_*__ tokens), it can still drift
# when we edit dex.yaml in repo (e.g. team allow-list changes,
# secretEnv/secret field swaps — that one bit us with `invalid_client`
# on first scheduler-admin login). Without restart, Dex keeps the
# previously-loaded YAML in memory.
#
# `bb-portal-backend` mounts ./config/bb-portal.jsonnet — same trap as
# scheduler/browser. We hit this on Phase 2a rollout: edits to
# browserServiceConfiguration / schedulerServiceConfiguration in
# bb-portal.jsonnet didn't take effect because docker compose up -d
# saw "no compose-spec change" and skipped recreation. Frontend
# changes WERE picked up (env vars in compose definition), so
# /browser welcome page rendered fine while gRPC-Web calls to
# /buildbarn.buildqueuestate.BuildQueueState/* on the BACKEND
# returned 404 ("schedulerConfiguration is not configured" path in
# grpcweb_proxy_server.go).
#
# `bb-portal-frontend` and `bb-portal-db` stay out of this list:
# the frontend's env vars are part of the compose spec, so any edit
# triggers normal recreation; the db is image+env only with no
# bind-mounted config to drift.
docker compose restart \
  scheduler \
  browser \
  frontend \
  storage-0 \
  storage-1 \
  dex \
  envoy-proxy \
  bb-portal-backend \
  scaler

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

  # 7982 / 7984 reachability is verified through the OIDC-redirect probe
  # below (a 302 → Dex /auth is the success signal post-Step 4). We
  # don't curl `/` for a 200 anymore because the OIDC handler now
  # intercepts every unauthenticated request and a `200 OK` here would
  # actually mean OIDC is misconfigured (placeholder fall-through to
  # allow{}). A bare TCP probe is enough to prove the listener is up
  # before we judge the redirect content.
  # 7986 added with bb-portal (Phase 1 coexistence — see plan); the other
  # two stay because we still expose standalone bb-browser :7984 and
  # bb-scheduler-admin :7982 alongside. Phase 2 collapses these.
  for tport in 7982 7984 7986; do
    if rssh "timeout 3 bash -c ':> /dev/tcp/127.0.0.1/$tport' 2>/dev/null"; then
      ok "TCP listener up on :$tport"
    else
      warn "no TCP listener on :$tport — check 'docker compose ps' / logs"
    fi
  done

  # 8981 = Envoy for Bazel clients. A bare TCP dial is enough to prove the
  # gateway is up without pulling in a grpc client — reachability alone is
  # the real signal here, and Envoy closes the connection on non-gRPC
  # traffic, which is fine for `nc -z`.
  if rssh "timeout 3 bash -c ':> /dev/tcp/127.0.0.1/8981' 2>/dev/null"; then
    ok "envoy-proxy accepting connections on :8981"
  else
    warn "envoy-proxy NOT accepting on :8981 — check 'docker compose logs envoy-proxy'"
  fi

  # 8980 (private) = bb-frontend's plaintext gRPC for ondemand workers.
  # This is the worker→CAS path that bypasses Envoy (workers live on the
  # Hetzner private network and don't carry Dex JWTs). Compose binds the
  # port on $PRIVATE_IP only — a probe from $PRIVATE_IP:8980 must succeed,
  # 0.0.0.0:8980 must NOT (proves we didn't accidentally publish CAS to
  # the public Internet, which would defeat Step 5's auth posture).
  if rssh "timeout 3 bash -c ':> /dev/tcp/$PRIVATE_IP/8980' 2>/dev/null"; then
    ok "frontend :8980 reachable on private IP $PRIVATE_IP (worker CAS path)"
  else
    warn "frontend :8980 NOT reachable on $PRIVATE_IP — check docker-compose.yml ports binding & 'docker compose ps frontend'"
  fi
  if rssh "timeout 3 bash -c ':> /dev/tcp/$PUBLIC_IP/8980' 2>/dev/null"; then
    warn "frontend :8980 ALSO listens on PUBLIC IP $PUBLIC_IP — should be private-only! check ports binding"
  else
    ok "frontend :8980 not exposed publicly (correct — workers only)"
  fi

  # 7984/7982 = bb-browser / bb-scheduler-admin OIDC redirect.
  # After Step 4 these UIs no longer return 200 on `/`; an
  # un-authenticated request gets a 302 to Dex /auth. We verify that
  # the redirect lands on our Dex `oidcIssuer` (and includes the
  # right `client_id` for each service) — a 200 here would mean
  # bake_env didn't replace the OIDC placeholders and BB silently
  # fell back to allow{}.
  # bb-portal-backend joins the OIDC family on :7986 — same posture as
  # browser/scheduler-admin. The svc-name token "bb-portal-backend" is
  # what `docker compose logs <svc>` expects (matches the service name
  # in compose/docker-compose.yml).
  for svc_pair in "browser:7984:bb-browser" "scheduler:7982:bb-scheduler-admin" "bb-portal-backend:7986:bb-portal"; do
    IFS=: read -r svc port client_id <<<"$svc_pair"
    local redir
    redir=$(curl -sS -o /dev/null -m 5 -w '%{redirect_url}' "https://$PUBLIC_HOSTNAME:$port/" || true)
    if [[ "$redir" == https://$PUBLIC_HOSTNAME:5556/auth?* && "$redir" == *"client_id=$client_id"* ]]; then
      ok "$svc :$port → 302 Dex /auth (client_id=$client_id)"
    elif [[ -z "$redir" ]]; then
      warn "$svc :$port — no redirect URL returned (200? OIDC disabled? — check 'docker compose logs $svc')"
    else
      warn "$svc :$port → unexpected redirect: $redir"
    fi
  done

  # 5556 = Dex OIDC. The discovery endpoint is the canonical liveness
  # probe — it's what every OIDC-aware client (bb-browser, bb-scheduler
  # in Step 4) hits FIRST when starting up, before any token exchange.
  # If discovery is broken, nothing downstream works.
  #
  # We additionally jq the response and assert that `issuer` matches
  # what we baked into dex.yaml: a mismatch means TLS is up but the
  # config is stale (e.g. an operator edited dex.yaml and forgot to
  # `docker compose restart dex`), which would silently break token
  # validation in step 4.
  local dex_issuer
  dex_issuer=$(curl -sSf -m 5 "https://$PUBLIC_HOSTNAME:5556/.well-known/openid-configuration" 2>/dev/null \
                | jq -r '.issuer // empty' 2>/dev/null || true)
  if [[ "$dex_issuer" == "https://$PUBLIC_HOSTNAME:5556" ]]; then
    ok "Dex OIDC discovery OK on https://$PUBLIC_HOSTNAME:5556 (issuer matches)"
  elif [[ -n "$dex_issuer" ]]; then
    warn "Dex up but issuer='$dex_issuer' != expected 'https://$PUBLIC_HOSTNAME:5556' — edit dex/dex.yaml and restart"
  else
    warn "Dex at https://$PUBLIC_HOSTNAME:5556 not serving discovery — check 'docker compose logs dex'"
  fi

  # Step 5: Dex JWKS endpoint must publish at least one signing key.
  # Envoy's jwt_authn filter on :8981 / :1985 caches JWKS for 60s
  # (PSMDB-2034 narrowed from 600s to shrink the post-rotation
  # stale-cache window — see envoy.yaml grpc_listener block). If the
  # set is empty (e.g. dex storage volume wiped without a fresh
  # bootstrap), every Bazel RPC is rejected with "Jwt verification
  # fails" until Dex re-mints a key. Catching it here means we don't
  # discover it from a developer's failed `bazel build`.
  local jwks_count
  jwks_count=$(curl -sSf -m 5 "https://$PUBLIC_HOSTNAME:5556/keys" 2>/dev/null \
                  | jq -r '.keys | length' 2>/dev/null || echo 0)
  if [[ "$jwks_count" -gt 0 ]]; then
    ok "Dex JWKS endpoint /keys exposes $jwks_count signing key(s)"
  else
    warn "Dex /keys missing or empty — Envoy jwt_authn will reject every RPC"
  fi

  # Step 5: confirm Envoy's jwt_authn filter is actually rejecting
  # unauthenticated traffic. We send a gRPC GetCapabilities call WITHOUT
  # an Authorization header and expect Envoy to short-circuit with
  # `grpc-message: Jwt is missing` (Envoy's default rejection text).
  # If we somehow get a normal Capabilities response back, the filter
  # silently isn't wired and EVERY anonymous client would have full
  # access to the cache + executor — exactly what Step 5 is here to
  # prevent.
  #
  # Run inside the scaler container: it ships grpcurl, has host
  # networking (so 127.0.0.1:8981 reaches the public Envoy listener),
  # and avoids us shipping grpcurl on the laptop. The TLS cert is for
  # the public hostname; -insecure tells grpcurl "speak TLS, skip
  # cert validation" which is what we want from inside the host.
  local envoy_unauth
  envoy_unauth=$(rssh "REMOTE_COMPOSE='$REMOTE_COMPOSE' bash -c 'cd \$REMOTE_COMPOSE && docker compose exec -T scaler grpcurl -insecure -d {} 127.0.0.1:8981 build.bazel.remote.execution.v2.Capabilities/GetCapabilities 2>&1'" || true)
  if grep -qiE 'jwt is missing|unauthenticated' <<<"$envoy_unauth"; then
    ok "envoy-proxy :8981 → rejects unauthenticated gRPC (jwt_authn filter ON)"
  elif grep -qiE 'cache_capabilities|execution_capabilities' <<<"$envoy_unauth"; then
    warn "envoy-proxy :8981 — Capabilities returned 200 WITHOUT auth (jwt_authn OFF or misrouted!) — check envoy.yaml http_filters order"
  else
    warn "envoy-proxy :8981 — could not classify unauth response: $(echo "$envoy_unauth" | head -3 | tr '\n' ' | ')"
  fi

  # bb-portal-db: the entrypoint runs initdb + creates the bbportal db on
  # first boot, then the container exposes :5432 internally. We don't
  # publish :5432 on the host (internal-only — see compose/docker-compose.yml
  # `expose: ["5432"]`), so we probe FROM INSIDE the container with
  # pg_isready. Failure here means either initdb hasn't completed yet
  # (cold-start race — bb-portal-backend will see "connection refused"
  # via pgx and crash-loop) OR the password env var didn't reach the
  # container. Cheap to run and surfaces the second class of bug
  # immediately rather than on the first BES event.
  if rssh "REMOTE_COMPOSE='$REMOTE_COMPOSE' bash -c 'cd \$REMOTE_COMPOSE && docker compose exec -T bb-portal-db pg_isready -q -U bbportal -d bbportal -h 127.0.0.1' >/dev/null 2>&1"; then
    ok "bb-portal-db accepting connections on :5432 (postgres up, bbportal db reachable)"
  else
    warn "bb-portal-db NOT ready — check 'docker compose logs bb-portal-db' for initdb errors / permission issues on /var/lib/buildbarn/portal-db"
  fi

  # Step 5/portal: bb-portal's /graphql endpoint must require auth.
  #
  # NB on which endpoint this is: bb-portal mounts TWO different paths
  # whose names look almost identical and routinely get confused —
  #   /graphql   ← the GraphQL API the Next.js UI calls. Always mounted,
  #                unconditionally (cmd/bb_portal/main.go:233). Disabling
  #                it would break every UI panel.
  #   /graphiql  ← interactive schema explorer (an unauthenticated
  #                playground UI). Mounted only when
  #                bb-portal.jsonnet::enableGraphqlPlayground is true.
  # We probe /graphql here — never /graphiql.
  #
  # We do NOT mint a real OIDC token (that would require shipping
  # rbe_login.py to the operator-laptop side of this smoke or standing
  # up a service-account in Dex — both out of scope for an unattended
  # post-deploy probe). Instead we assert the OIDC middleware rejects
  # an anonymous POST: a 401 (no auth header) or a 302 (redirect to
  # Dex /auth) both prove the gate is wired. A 200 here would mean
  # bake_env did not replace the OIDC placeholders and bb-portal
  # silently fell back to allow{} — same failure mode as the bb-browser
  # / bb-scheduler-admin probes above. End-to-end "GraphQL returns
  # real invocations under a real token" verification is left to the
  # operator runbook in ondemand/README.md §"Finding a historical build".
  local gql_status
  gql_status=$(curl -sS -o /dev/null -m 5 -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d '{"query":"{ invocations(first:1){nodes{id}}}"}' \
    "https://$PUBLIC_HOSTNAME:7986/graphql" 2>/dev/null || true)
  # Accept 401 (no auth header → API rejection), 302 (Found —
  # browser-style redirect for GET), or 303 (See Other — POST→GET
  # coercion per RFC 7231 §6.4.4, which is what bb-storage's OIDC
  # handler emits for unauthenticated POSTs because redirecting POST
  # bodies to a Dex /auth login is meaningless). Anything else means
  # the OIDC middleware did NOT engage.
  if [[ "$gql_status" =~ ^(302|303|401)$ ]]; then
    ok "bb-portal /graphql → $gql_status without auth (OIDC gate ON)"
  else
    warn "bb-portal /graphql returned '$gql_status' without auth — expected 302/303/401; check 'docker compose logs bb-portal-backend' for OIDC config"
  fi

  # Phase 2a: bb-portal /browser/ and /scheduler/ routes are now wired
  # (browserServiceConfiguration / schedulerServiceConfiguration in
  # bb-portal.jsonnet point at frontend:8980 and scheduler:8984
  # respectively). Both routes must sit behind the same OIDC gate as
  # the BES /graphql probe above. We confirm with a simple GET; for
  # GET, bb-storage's authenticatingHandler emits a 302 redirect to
  # Dex /auth (not 303 — that's POST→GET coercion only). 401 is also
  # acceptable in case someone wires a non-redirect response later.
  for route in browser scheduler; do
    local route_status
    route_status=$(curl -sS -o /dev/null -m 5 -w '%{http_code}' \
      "https://$PUBLIC_HOSTNAME:7986/$route/" 2>/dev/null || true)
    if [[ "$route_status" =~ ^(302|303|401)$ ]]; then
      ok "bb-portal /$route → $route_status without auth (OIDC gate ON)"
    else
      warn "bb-portal /$route returned '$route_status' without auth — expected 302/303/401; check 'docker compose logs bb-portal-backend' for ${route}ServiceConfiguration wiring"
    fi
  done

  # Step 5/portal: confirm Envoy's jwt_authn filter on :1985 (the new
  # BES listener) also rejects unauthenticated traffic. Same logic as
  # the :8981 probe above — copy-paste with the port flipped, because
  # the two listeners share the dex_provider config and a regression in
  # one is almost certainly a regression in both.
  local bes_unauth
  bes_unauth=$(rssh "REMOTE_COMPOSE='$REMOTE_COMPOSE' bash -c 'cd \$REMOTE_COMPOSE && docker compose exec -T scaler grpcurl -insecure -d {} 127.0.0.1:1985 google.devtools.build.v1.PublishBuildEvent/PublishLifecycleEvent 2>&1'" || true)
  if grep -qiE 'jwt is missing|unauthenticated' <<<"$bes_unauth"; then
    ok "envoy-proxy :1985 → rejects unauthenticated BES gRPC (jwt_authn filter ON)"
  elif grep -qiE 'method PublishLifecycleEvent not implemented|invalid argument' <<<"$bes_unauth"; then
    warn "envoy-proxy :1985 — request reached bb-portal-backend WITHOUT auth (jwt_authn OFF or misrouted!) — check envoy.yaml http_filters order on bes_grpc_listener"
  else
    warn "envoy-proxy :1985 — could not classify unauth response: $(echo "$bes_unauth" | head -3 | tr '\n' ' | ')"
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
    bb-portal        : https://$PUBLIC_HOSTNAME:7986/
                       (build observability — invocation history, action timelines;
                        see buildbarn-portal-plan.md. Phase 1: coexists with
                        bb-browser :7984 and scheduler-admin :7982.)
    Bazel clients    : grpcs://$PUBLIC_HOSTNAME:8981  (TLS terminated by Envoy)
    BES (build events): grpcs://$PUBLIC_HOSTNAME:1985 (TLS+JWT terminated by Envoy
                       → bb-portal-backend; --bes_backend in .bazelrc.psmdb)
    Dex (OIDC IdP)   : https://$PUBLIC_HOSTNAME:5556/.well-known/openid-configuration
                       (browser, scheduler-admin & bb-portal redirect here for GitHub OAuth → team check)

    NB: We always print the DNS hostname here, never the raw \$PUBLIC_IP
    ($PUBLIC_IP). The hostname resolves to the Hetzner Floating IP
    that's pinned to this VM and survives VM redeploys; the primary
    \$PUBLIC_IP can rotate. Browsing https://<floating-ip>:7982/ also
    fails TLS validation because the cert SAN is the hostname, not the
    IP — always use the hostname.
EOF

  # Floating IP / primary block — split out of the main heredoc so we can
  # branch on whether ensure_floating_ip overrode PUBLIC_IP. Bash's
  # nested-heredoc + $() expansion combo doesn't parse cleanly inside an
  # outer heredoc, hence the second cat <<EOF here.
  if [[ -n "$PUBLIC_IP_PRIMARY" ]]; then
    cat <<EOF

  Floating IP / primary IP:
    \$PUBLIC_IP        : $PUBLIC_IP  (Floating IP $FLOATING_IP_ID — used by all script ops)
    Primary fallback : $PUBLIC_IP_PRIMARY  (VM's eth0 public IPv4 — direct SSH if FIP routing breaks)
EOF
  else
    cat <<EOF

  Public IP:
    \$PUBLIC_IP        : $PUBLIC_IP  (VM primary — FLOATING_IP_ID not set, no FIP indirection)
EOF
  fi

  cat <<EOF

  Private (psmdb.cd.percona.com network):
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
  ensure_floating_ip            # API-level only; no $PUBLIC_IP override here
  wait_for_ssh                  # via primary IP — FIP alias not configured yet
  bootstrap_host                # installs docker + ifupdown helpers
  configure_floating_ip_on_host # OS-level alias + persist + flip $PUBLIC_IP→FIP
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
