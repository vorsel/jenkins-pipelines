#!/usr/bin/env bash
#
# diag-envoy-PSMDB-2034.sh — collect evidence around Envoy / kernel state
# during a Bazel matrix burst. Goal is to disprove or confirm the
# remaining guesses for the `SslHandshakeTimeoutException` after the
# server-side burst patch (envoy listeners + sysctl) was already applied:
#
#   * Is Envoy actually running with `concurrency` matching cpu count
#     (16 on cpx62)? — `/server_info`.
#   * Is the `reuse_port: true` patch live so we have N independent
#     listening sockets on :8981 / :1985? — `ss -tnlp`.
#   * Are the cluster circuit_breakers overflowing despite the 100k
#     ceiling? — `/clusters` overflow counters.
#   * Are TLS handshakes themselves failing on the server side
#     (e.g. cert load issues, no_filter_chain_match)? — listener
#     ssl.* and downstream_cx_* counters.
#   * Are Envoy worker threads CPU-bound? — `top -H` of envoy pid.
#
# Modes:
#   ./diag-envoy-PSMDB-2034.sh start    — write baseline snapshot to
#       /tmp/envoy-diag-PSMDB-2034/baseline.txt and spawn a background
#       loop dumping live snapshots into rolling.log every 5s.
#   ./diag-envoy-PSMDB-2034.sh stop     — kill the background loop,
#       capture a final snapshot, print human-readable diff.
#   ./diag-envoy-PSMDB-2034.sh status   — show whether a sampler is
#       currently running and where its log is.
#
# Designed to run from the OPERATOR workstation (uses ~/.config/psmdb-rbe/
# cluster.env to find central). All heavy lifting happens on the central
# host — script ssh's in and runs a small inline sampler.

set -euo pipefail

CLUSTER_ENV="${CLUSTER_ENV:-$HOME/.config/psmdb-rbe/cluster.env}"
[[ -r "$CLUSTER_ENV" ]] || { echo "FATAL: cluster.env missing/unreadable: $CLUSTER_ENV" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CLUSTER_ENV"

: "${PUBLIC_HOSTNAME:?PUBLIC_HOSTNAME not set in $CLUSTER_ENV}"
: "${SSH_PRIV_KEY:=$HOME/.ssh/htz.cd.bb-psmdb-ondemand.key}"
[[ -r "$SSH_PRIV_KEY" ]] || { echo "FATAL: ssh private key not readable: $SSH_PRIV_KEY" >&2; exit 1; }

SSH_OPTS=(
  -i "$SSH_PRIV_KEY"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts"
)

REMOTE_DIR="/tmp/envoy-diag-PSMDB-2034"
ADMIN="http://127.0.0.1:9901"

cmd="${1:-help}"

case "$cmd" in
  start)
    echo ">> diag target : root@$PUBLIC_HOSTNAME"
    echo ">> remote dir  : $REMOTE_DIR"
    echo ">> admin url   : $ADMIN"

    ssh "${SSH_OPTS[@]}" "root@$PUBLIC_HOSTNAME" \
        "REMOTE_DIR='$REMOTE_DIR'" "ADMIN='$ADMIN'" \
        "bash -se" <<'REMOTE'
set -euo pipefail

# Ensure Envoy admin is reachable. Without it we can't gather any of the
# server-side counters that distinguish "kernel queued and Envoy didn't
# accept fast enough" from "Envoy accepted but TLS handshake hung".
if ! curl -fsS --max-time 2 "$ADMIN/ready" >/dev/null; then
  echo "FATAL: Envoy admin $ADMIN/ready not reachable inside central" >&2
  echo "       Check that envoy-proxy container is up and that the" >&2
  echo "       127.0.0.1:9901:9901 mapping in docker-compose.yml is alive." >&2
  exit 1
fi

mkdir -p "$REMOTE_DIR"
cd "$REMOTE_DIR"

snapshot() {
  local out="$1"
  {
    echo "=== $(date -Iseconds) ==="
    echo
    echo "--- /server_info (concurrency expected to match nproc=$(nproc)) ---"
    curl -fsS "$ADMIN/server_info" | python3 -c '
import json,sys
d = json.load(sys.stdin)
print(f"  state            : {d.get(\"state\")}")
print(f"  concurrency      : {d.get(\"concurrency\")}")
print(f"  uptime_all_epochs: {d.get(\"uptime_all_epochs\")}s")
print(f"  hot_restart_ver  : {d.get(\"hot_restart_version\")}")
print(f"  command_line     : {d.get(\"command_line_options\",{}).get(\"concurrency\",\"<auto>\")}")
'
    echo
    echo "--- ss -tnlp on :8981 / :1985 (one entry per worker if reuse_port works) ---"
    ss -tnlp '( sport = :8981 or sport = :1985 )' | head -40
    echo
    echo "--- listener counters (downstream_cx_* + ssl.*) ---"
    curl -fsS "$ADMIN/stats?filter=^listener\\.0\\.0\\.0\\.0_(8981|1985)\\.(downstream_cx_(total|active|destroy|length|overload|destroy_local|destroy_remote)|ssl\\.(connection_error|handshake|fail_verify_no_cert|fail_verify_error|fail_verify_cert_hash|no_certificate))$"
    echo
    echo "--- cluster circuit-breaker overflows + active connections ---"
    curl -fsS "$ADMIN/stats?filter=^cluster\\.(buildbarn_frontend|capabilities_proxy|bb_portal_bes)\\.(upstream_cx_(overflow|active|connect_fail|connect_timeout|total)|upstream_rq_(pending_overflow|active|retry_overflow))$"
    echo
    echo "--- worker thread distribution (per-worker downstream_cx_active) ---"
    curl -fsS "$ADMIN/stats?filter=^listener\\.worker_[0-9]+\\.downstream_cx_(active|total)$" | sort
    echo
    echo "--- nstat (TCP-layer drops/retrans) ---"
    nstat -az TcpExtListenOverflows TcpExtListenDrops TcpExtTCPBacklogDrop TcpExtTCPSynRetrans TcpExtTCPRetransSegs TcpExtTCPAbortOnTimeout TcpExtTCPTimeWaitOverflow 2>/dev/null | column -t
    echo
    echo "--- envoy proc CPU (top -H -b -n1, top 5 threads) ---"
    ENVOY_PID="$(docker inspect -f '{{.State.Pid}}' bb-psmdb-ondemand-envoy-proxy-1 2>/dev/null || true)"
    if [[ -n "$ENVOY_PID" && "$ENVOY_PID" != "0" ]]; then
      top -H -b -n1 -p "$ENVOY_PID" | tail -n +7 | head -10
    else
      echo "  envoy-proxy container pid not resolvable"
    fi
  } >"$out" 2>&1
}

# Baseline snapshot — a single capture before the next Jenkins burst.
snapshot baseline.txt
echo ">> baseline written: $REMOTE_DIR/baseline.txt"

# Background sampler — every 5s appends a snapshot to rolling.log.
# We refuse to start a second one to avoid duplicate writes.
PIDFILE="$REMOTE_DIR/sampler.pid"
if [[ -s "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "WARN: sampler already running (pid $(cat "$PIDFILE")) — leaving it" >&2
else
  : >rolling.log
  (
    while true; do
      snapshot /tmp/envoy-diag-PSMDB-2034/.tmp.snap
      cat /tmp/envoy-diag-PSMDB-2034/.tmp.snap >>/tmp/envoy-diag-PSMDB-2034/rolling.log
      echo >>/tmp/envoy-diag-PSMDB-2034/rolling.log
      sleep 5
    done
  ) </dev/null >/dev/null 2>&1 &
  SAMPLER_PID=$!
  echo "$SAMPLER_PID" >"$PIDFILE"
  disown "$SAMPLER_PID" 2>/dev/null || true
  echo ">> sampler started: pid=$SAMPLER_PID, rolling.log=$REMOTE_DIR/rolling.log"
fi

echo
echo ">> NOW: trigger the Jenkins matrix build."
echo ">> When it finishes (passed OR failed) — run:"
echo ">>   $(basename "$0") stop"
REMOTE
    ;;

  stop)
    ssh "${SSH_OPTS[@]}" "root@$PUBLIC_HOSTNAME" \
        "REMOTE_DIR='$REMOTE_DIR'" "ADMIN='$ADMIN'" \
        "bash -se" <<'REMOTE'
set -euo pipefail
cd "$REMOTE_DIR"

PIDFILE="$REMOTE_DIR/sampler.pid"
if [[ -s "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  kill "$(cat "$PIDFILE")" || true
  rm -f "$PIDFILE"
  echo ">> sampler stopped"
else
  echo "WARN: no running sampler found"
fi

# Final snapshot for diff vs baseline.
{
  echo "=== $(date -Iseconds) FINAL ==="
  echo
  echo "--- /server_info ---"
  curl -fsS "$ADMIN/server_info" | python3 -m json.tool 2>/dev/null | head -40 || true
  echo
  echo "--- ss -tnlp ---"
  ss -tnlp '( sport = :8981 or sport = :1985 )' | head -40
  echo
  echo "--- listener + cluster + worker stats (raw) ---"
  curl -fsS "$ADMIN/stats?filter=^(listener\\.(0\\.0\\.0\\.0_(8981|1985)|worker_[0-9]+)|cluster\\.(buildbarn_frontend|capabilities_proxy|bb_portal_bes))\\." | sort
  echo
  echo "--- nstat ---"
  nstat -az TcpExtListenOverflows TcpExtListenDrops TcpExtTCPBacklogDrop TcpExtTCPSynRetrans TcpExtTCPRetransSegs TcpExtTCPAbortOnTimeout TcpExtTCPTimeWaitOverflow 2>/dev/null | column -t
} >final.txt 2>&1
echo ">> final snapshot written: $REMOTE_DIR/final.txt"

# Cheap human-readable summary: pull the most relevant counters out of
# baseline.txt vs final.txt and show side-by-side. This is the file the
# operator actually pastes back to chat.
python3 - "$REMOTE_DIR/baseline.txt" "$REMOTE_DIR/final.txt" >"$REMOTE_DIR/summary.txt" <<'PY'
import re, sys, pathlib

paths = [pathlib.Path(p) for p in sys.argv[1:]]
labels = ["BASELINE", "FINAL"]

# Pick out lines that look like `key: value` (envoy /stats output is
# `name: number`, ss output is structured, etc.). We only care about
# numeric stat lines for the diff.
stat_re = re.compile(r"^([\w\.\d-]+):\s+(-?\d+)\s*$")

def grab(p):
    out = {}
    for ln in p.read_text(errors="replace").splitlines():
        m = stat_re.match(ln.strip())
        if m:
            out[m.group(1)] = int(m.group(2))
    return out

snaps = [grab(p) for p in paths]
keys = sorted(set().union(*[s.keys() for s in snaps]))

# Subset of keys that matter most for the SSL-handshake-timeout root
# cause. Anything outside this list is interesting only when nonzero.
prio_substrings = (
    "listener.0.0.0.0_8981.downstream_cx_",
    "listener.0.0.0.0_8981.ssl.",
    "listener.0.0.0.0_1985.downstream_cx_",
    "listener.0.0.0.0_1985.ssl.",
    "cluster.buildbarn_frontend.upstream_cx_",
    "cluster.buildbarn_frontend.upstream_rq_pending_",
    "cluster.bb_portal_bes.upstream_cx_",
    "TcpExtListenOverflows",
    "TcpExtListenDrops",
    "TcpExtTCPBacklogDrop",
    "TcpExtTCPSynRetrans",
    "TcpExtTCPAbortOnTimeout",
    "worker_",
)

print(f"{'KEY':80s}  {labels[0]:>12s}  {labels[1]:>12s}  {'Δ':>12s}")
print("-" * 130)
for k in keys:
    if not any(s in k for s in prio_substrings):
        continue
    a = snaps[0].get(k, 0); b = snaps[1].get(k, 0)
    if a == b == 0:
        continue
    print(f"{k:80s}  {a:12d}  {b:12d}  {(b-a):+12d}")
PY

echo
echo "=== summary.txt ==="
cat "$REMOTE_DIR/summary.txt"
echo
echo ">> full files retained on central (paste back if more detail needed):"
echo ">>   $REMOTE_DIR/baseline.txt"
echo ">>   $REMOTE_DIR/rolling.log     (every-5s during the burst)"
echo ">>   $REMOTE_DIR/final.txt"
REMOTE
    ;;

  status)
    ssh "${SSH_OPTS[@]}" "root@$PUBLIC_HOSTNAME" "REMOTE_DIR='$REMOTE_DIR'" bash -se <<'REMOTE'
set -euo pipefail
PIDFILE="$REMOTE_DIR/sampler.pid"
if [[ -s "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo ">> sampler RUNNING (pid $(cat "$PIDFILE"))"
  echo ">> rolling.log size: $(wc -c <"$REMOTE_DIR/rolling.log" 2>/dev/null || echo 0) bytes"
else
  echo ">> no sampler running"
fi
ls -la "$REMOTE_DIR" 2>/dev/null || echo "  (no $REMOTE_DIR yet)"
REMOTE
    ;;

  *)
    cat <<USAGE
Usage:
  $0 start   — capture baseline + start a 5s sampler (one-time per burst)
  $0 stop    — stop sampler, capture final, print summary diff
  $0 status  — check whether a sampler is running on central

Workflow:
  1. $0 start                 # before triggering Jenkins
  2. trigger the Jenkins matrix and wait until it finishes (pass or fail)
  3. $0 stop                  # paste the printed summary back to chat

The summary highlights:
  * Envoy concurrency (must match nproc on central — 16 on cpx62).
  * reuse_port socket count on :8981 (one per worker if patch is live).
  * Δ in downstream_cx_total / ssl.connection_error / circuit_breakers
    overflow counters during the burst — those isolate which layer is
    actually rejecting connections.
USAGE
    exit 2
    ;;
esac
