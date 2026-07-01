#!/usr/bin/env bash
#
# setup-wireguard-hub.sh — stand up the WireGuard hub on the central host.
#
# The hub is the rendezvous point for AWS Graviton fallback workers (see
# ../../aws-graviton-fallback.md). Each AWS worker is a spoke that peers with
# this hub and routes the central's PRIVATE Hetzner IP through the tunnel, so
# the worker dials the exact same `:8980` / `:8983` a Hetzner worker would.
#
# Peers are NOT configured here — the scaler adds/removes them at runtime via
# `wg set wg0 peer …` (that's why SaveConfig=false below: a wg-quick restart
# resets to a peerless interface and the scaler's reconcile loop re-adds the
# live workers on its next tick).
#
# Run ON the central host (it needs root + the public/Floating IP). Idempotent:
# re-running preserves the existing hub keypair and just re-asserts wg0.conf.
#
# Usage (on the central):
#   sudo WG_HUB_IP=10.99.0.1 WG_CIDR=10.99.0.0/16 WG_PORT=51820 \
#        ./setup-wireguard-hub.sh
#
# The tunnel routes ONLY the central's private IP — RBE workers don't reach
# repo.ci.percona.com (that's the Jenkins agent's job), so no ip_forward / SNAT
# / NAT is configured here.
set -euo pipefail

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root on the central host"

WG_IFACE="${WG_IFACE:-wg0}"
WG_HUB_IP="${WG_HUB_IP:-10.99.0.1}"
WG_CIDR="${WG_CIDR:-10.99.0.0/16}"
WG_PORT="${WG_PORT:-51820}"
WG_PREFIX="${WG_CIDR##*/}"          # mask length, e.g. 16
CONF="/etc/wireguard/${WG_IFACE}.conf"
PRIV="/etc/wireguard/${WG_IFACE}-hub.key"
PUB="/etc/wireguard/${WG_IFACE}-hub.pub"

log "Installing wireguard-tools"
export DEBIAN_FRONTEND=noninteractive
if ! command -v wg >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y --no-install-recommends wireguard wireguard-tools
fi
ok "wg present: $(wg --version)"

log "Ensuring hub keypair"
umask 077
mkdir -p /etc/wireguard
if [[ ! -s "$PRIV" ]]; then
  wg genkey | tee "$PRIV" | wg pubkey > "$PUB"
  ok "generated new hub keypair"
else
  ok "reusing existing hub keypair ($PRIV)"
fi
HUB_PUBKEY="$(cat "$PUB")"

log "Writing $CONF"
# SaveConfig=false: peers are runtime-only (managed by the scaler) — a
# wg-quick restart resets to a peerless interface and the scaler's
# reconcile loop re-adds the live workers on its next tick. The hub only
# terminates the tunnel; it does no forwarding/NAT (workers reach the
# central's own private IP, delivered locally on wg0).
{
  echo "[Interface]"
  echo "Address = ${WG_HUB_IP}/${WG_PREFIX}"
  echo "ListenPort = ${WG_PORT}"
  echo "PrivateKey = $(cat "$PRIV")"
  echo "SaveConfig = false"
} > "$CONF"
chmod 600 "$CONF"
ok "wrote $CONF"

log "Enabling wg-quick@${WG_IFACE}"
systemctl enable "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
# `restart` (not just start) so an edited conf takes effect on re-run.
systemctl restart "wg-quick@${WG_IFACE}"
systemctl is-active --quiet "wg-quick@${WG_IFACE}" || die "wg-quick@${WG_IFACE} failed to start (journalctl -u wg-quick@${WG_IFACE})"
ok "$WG_IFACE is up: $(ip -brief addr show "$WG_IFACE" | awk '{print $3}')"

cat <<EOF

────────────────────────────────────────────────────────────────────────────
WireGuard hub is up. Now wire the scaler to it:

1) Open UDP ${WG_PORT} INBOUND on the central:
   - Hetzner Cloud Firewall (if attached to the central): add an inbound rule
     for udp/${WG_PORT} from 0.0.0.0/0 (workers come from AWS public IPs).
   - Host firewall, if any: allow udp/${WG_PORT}.

2) Put these in compose/.env (or the operator cluster.env) and redeploy:

   WG_HUB_PUBKEY=${HUB_PUBKEY}
   WG_HUB_ENDPOINT=<central-floating-ip-or-PUBLIC_HOSTNAME>:${WG_PORT}
   WG_ALLOWED_IPS=<central-private-ip>/32

   (WG_ALLOWED_IPS may be left blank — the scaler defaults to
    "<scheduler_private_ip>/32" from ondemand-pools.yaml.)

3) Set aws.enabled: true + the aws: block in compose/config/ondemand-pools.yaml,
   fill the AWS_* creds/ids in .env, then:
   docker compose up -d scaler && docker compose logs -f scaler
────────────────────────────────────────────────────────────────────────────
EOF
