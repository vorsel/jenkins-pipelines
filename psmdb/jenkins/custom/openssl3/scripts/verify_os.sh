#!/bin/bash
# All checks for one OS; mongod runs on that OS, the client in the helper container here
# (via ssh port forwards in ssh mode).
#   verify_os.sh container ID IDX IMAGE              # host kernel
#   verify_os.sh ssh       ID IDX HOST USER KEYFILE  # VM, its own kernel
# env: T (from helper_setup.sh: pkg/ rt/ [vendor/] verify/), OUT, HELPER, OPENSSL_VERSION
# writes $OUT/<IDX>-<ID>.tsv: OS_ID, check, PASS|FAIL|INFO, detail; keeps going after a FAIL
set -uo pipefail
MODE=$1 ID=$2 IDX=$3
: "${T:?}" "${OUT:?}"
mkdir -p "$OUT"
HELPER=${HELPER:-oscheck-helper}
TAB=$OUT/$(printf %02d "$IDX")-$ID
PORT=$((27000 + IDX * 20))
PKG=$(basename "$(ls -d "$T"/pkg/percona-server-mongodb-*)")
BIN=/work/pkg/$PKG/bin/mongod
S=/work/vendor
D=/work/rt
LDSO=/lib64/ld-linux-x86-64.so.2
CERTS="--tlsMode requireTLS --tlsCertificateKeyFile /work/verify/certs/server.pem --tlsCAFile /work/verify/certs/ca.pem --tlsAllowConnectionsWithoutCertificates"
exec >"$TAB.log" 2>&1
rm -f "$TAB.tsv"

res() { printf '%s\t%s\t%s\t%s\n' "$ID" "$1" "$2" "${3:-}" | tee -a "$TAB.tsv"; }
chk() { local name=$1 detail=$2; shift 2; if "$@"; then res "$name" PASS "$detail"; else res "$name" FAIL "$detail"; fi; }
nogrep() { ! grep -q "$1" <<<"$2"; }
lp() { echo "$1/opt/mongo/openssl3/lib:$1/lib"; }      # same LD_LIBRARY_PATH order as the customer

# ---- executor
case $MODE in
container)
    IMG=$4 C=oscheck-$ID
    RD=$(mktemp -d)
    dx() { docker exec "$C" "$@"; }
    fwd() { :; }; unfwd() { :; }
    cleanup() { docker rm -f "$C" >/dev/null 2>&1; rm -rf "$RD"; }
    trap cleanup EXIT
    docker rm -f "$C" >/dev/null 2>&1
    if ! docker pull -q "$IMG" >/dev/null 2>&1; then res pull FAIL "image pull failed: $IMG"; exit 0; fi
    # --init so killed mongods get reaped and /proc/<pid> really goes away
    docker run -d --init --name "$C" --network host -v "$T":/work:ro -v "$RD":/poc "$IMG" sleep infinity >/dev/null
    ;;
ssh)
    HOST=$4 USER_=$5 KEY=$6
    SOCK=$(mktemp -u /tmp/oscheck-$ID.XXXX)
    SSH=(ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=15 -S "$SOCK")
    dx() { "${SSH[@]}" "$USER_@$HOST" "sudo $(printf '%q ' "$@")"; }
    fwd() { "${SSH[@]}" -O forward -L "127.0.0.1:$1:127.0.0.1:$1" "$USER_@$HOST" 2>/dev/null; }
    unfwd() { "${SSH[@]}" -O cancel -L "127.0.0.1:$1:127.0.0.1:$1" "$USER_@$HOST" 2>/dev/null; }
    cleanup() { "${SSH[@]}" -O exit "$USER_@$HOST" 2>/dev/null; }
    trap cleanup EXIT
    "${SSH[@]}" -M -f -N "$USER_@$HOST" || { res ssh FAIL "no ssh to $HOST"; exit 0; }
    # minimal images (the OL factory ones) come without tar
    "${SSH[@]}" "$USER_@$HOST" 'command -v tar >/dev/null || sudo dnf -y -q install tar || sudo yum -y -q install tar ||
        sudo zypper -n -q install tar || { sudo apt-get -q update && sudo apt-get -y -q install tar; }' >/dev/null 2>&1 \
        || { res upload FAIL "no tar on $HOST and could not install it"; exit 0; }
    # vendor/ only if present: the customer bundle never leaves our hosts except to these test VMs
    tar -C "$T" -czf - pkg rt verify $( [ -d "$T/vendor" ] && echo vendor ) \
        | "${SSH[@]}" "$USER_@$HOST" 'sudo mkdir -p /work /poc && sudo tar -xzf - -C /work' \
        || { res upload FAIL "copy to $HOST failed"; exit 0; }
    ;;
*) echo "unknown mode $MODE"; exit 2 ;;
esac
rcat() { dx cat "/poc/$1" 2>/dev/null; }
mlog() { rcat "$1.log"; rcat "$1.out"; }    # .out: what mongod printed before its log file was open
dx mkdir -p /poc/nomods

os=$(dx cat /etc/os-release | sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')
glibc=$(dx $LDSO --version 2>&1 | grep -oE 'version [0-9.]+' | head -1 | cut -d' ' -f2 | sed 's/\.$//')
kernel=$(dx uname -r)
res os INFO "$os | glibc $glibc | kernel $kernel | $MODE"

# 8.0.34 refuses to start with tcmalloc per-CPU caches on 6.19.0-7.0.13 (startup_check_rseq.cpp)
kv=$(grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' <<<"$kernel")
in_range() { [ "$(printf '%s\n%s\n' 6.19.0 "$1" | sort -V | head -1)" = 6.19.0 ] && [ "$(printf '%s\n%s\n' "$1" 7.0.13 | sort -V | head -1)" = "$1" ]; }
KERNEL_GUARD=0; [ -n "$kv" ] && in_range "$kv" && KERNEL_GUARD=1
[ $KERNEL_GUARD = 1 ] && res kernel INFO "kernel $kernel is in the 6.19.0-7.0.13 guard range"

# ---- dynamic linking
ldd_check() { # tag root
    local out; out=$(dx env LD_LIBRARY_PATH="$(lp "$2")" $LDSO --list "$BIN" 2>&1)
    echo "== ldd $1"; echo "$out" | sed 's/ (0x.*//'
    echo "$out" | sed 's/ (0x.*//' | awk -v r="$2" '{ p=$3; sub(r, "X", p); print $1, p }' | sort > "$TAB.ldd_$1"
    chk "ldd_$1" "all resolved" nogrep 'not found' "$out"
    chk "no_ossl11_$1" "no libssl/libcrypto 1.1" nogrep 'so\.1\.1' "$out"
    local n; n=$(grep -c " $2/" <<<"$out")
    chk "from_layout_$1" "$n libs from $2 (expect 13)" test "$n" -eq 13
}
[ -d "$T/vendor" ] && ldd_check vendor $S
ldd_check ours $D
[ -d "$T/vendor" ] && chk ldd_same "our libs resolve like the vendor bundle" diff "$TAB.ldd_vendor" "$TAB.ldd_ours"
rm -f "$TAB".ldd_*

v=$(dx env LD_LIBRARY_PATH="$(lp $D)" "$BIN" --version 2>&1)
OSSL_V=$(grep -oE 'OpenSSL [0-9.]+' <<<"$v" | head -1)
if [ -n "${OPENSSL_VERSION:-}" ]; then chk version "$OSSL_V" test "$OSSL_V" = "OpenSSL $OPENSSL_VERSION"; else res version INFO "$OSSL_V"; fi

# ---- server cases
mstart() { # name envs... -- extra mongod args
    local n=$1; shift; local envs=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
    PORT=$((PORT + 1))
    dx rm -rf "/poc/$n"; dx mkdir -p "/poc/$n"
    # detach stdio on the far side too, or the ssh session would hang on the forked mongod;
    # keep it in a file: the kernel guard fires before --logpath is open
    local cmd; cmd=$(printf '%q ' env "${envs[@]}" "$BIN" --dbpath "/poc/$n" --port $PORT --bind_ip 127.0.0.1 \
        --replSet kv --fork --logpath "/poc/$n.log" --pidfilepath "/poc/$n.pid" $CERTS "$@")
    dx bash -c "$cmd </dev/null >/poc/$n.out 2>&1"
}
started_or_guard() { # name -> 0 started, 1 failed, 2 refused by the kernel guard
    if mstart "$@"; then fwd $PORT; return 0; fi
    if [ $KERNEL_GUARD = 1 ] && mlog "$1" | grep -q '"id":12257600'; then return 2; fi
    return 1
}
mstop() {
    local pid; pid=$(rcat "$1.pid") || return 0; [ -n "$pid" ] || return 0
    unfwd $PORT
    dx bash -c "kill $pid" 2>/dev/null
    for _ in $(seq 60); do dx test -d "/proc/$pid" || return 0; sleep 1; done
    dx bash -c "kill -9 $pid" 2>/dev/null
}
maps() { dx cat "/proc/$(rcat "$1.pid")/maps" 2>/dev/null; }
client() { docker exec "$HELPER" python3.11 /work/verify/client.py $PORT 2>&1 | tail -1; }
sclient() { # cipher -> handshake summary
    local out; out=$(echo | docker exec -i "$HELPER" env LD_LIBRARY_PATH=/work/rt/lib /work/rt/bin/openssl \
        s_client -connect 127.0.0.1:$PORT -cipher "$1" -tls1_2 -CAfile /work/verify/certs/ca.pem 2>&1)
    grep -m1 -E '^New,|Cipher is' <<<"$out"
}
start_result() { # name rc
    case $2 in
        0) res "${1}_start" PASS ;;
        2) res "${1}_start" PASS "refused by kernel guard 12257600 (expected on $kernel)" ;;
        *) res "${1}_start" FAIL "$(mlog "$1" | tail -c 400)" ;;
    esac
}

tls_case() { # name root [extra env]
    local n=$1 r=$2 out rc; shift 2
    started_or_guard "$n" LD_LIBRARY_PATH="$(lp "$r")" "$@" --; rc=$?
    start_result "$n" $rc; PERCPU=$([ $rc = 2 ] && echo guard || echo "")
    if [ $rc = 0 ]; then
        out=$(client); echo "$n client: $out"
        chk "${n}_kv" "$out" grep -q "^OK openssl=OpenSSL_${OSSL_V#OpenSSL }" <<<"$out"
        chk "${n}_libssl" "libssl.so.3 from $r" grep -q " $r/lib/libssl.so.3$" <<<"$(maps "$n")"
        PERCPU=$(grep -oE 'perCPU=[A-Za-z]+' <<<"$out" | cut -d= -f2)
        [ $KERNEL_GUARD = 1 ] && chk "${n}_guard" "per-CPU caches off on guarded kernel" test "$PERCPU" != True
    fi
    mstop "$n"
}

# vendor openssl.cnf includes its fipsmodule.cnf via $ENV::<root var>; set every such var to the root
cnf_envs() { # host-side cnf, root on the target
    grep -oE 'ENV::[A-Za-z_][A-Za-z0-9_]*' "$1" | cut -d: -f3 | sort -u | sed "s|\$|=$2|"
}

fips_case() { # name root openssl.cnf modules-dir [extra env]
    local n=$1 r=$2 cnf=$3 mods=$4 out h rc; shift 4
    started_or_guard "$n" "$@" OPENSSL_CONF="$cnf" OPENSSL_MODULES="$mods" LD_LIBRARY_PATH="$(lp "$r")" -- --tlsFIPSMode; rc=$?
    start_result "$n" $rc
    if [ $rc = 0 ]; then
        chk "${n}_fipslog" "FIPS 140 mode activated" grep -q '"FIPS 140 mode activated"' <<<"$(rcat "$n.log")"
        chk "${n}_fipsso" "$mods/fips.so mapped" grep -q " $mods/fips.so$" <<<"$(maps "$n")"
        out=$(client); echo "$n client: $out"
        chk "${n}_kv" "$out" grep -q '^OK openssl=' <<<"$out"
        h=$(sclient ECDHE-RSA-CHACHA20-POLY1305)
        chk "${n}_chacha_refused" "$h" grep -q 'Cipher is (NONE)' <<<"$h"
        h=$(sclient ECDHE-RSA-AES256-GCM-SHA384)
        chk "${n}_aesgcm_ok" "$h" grep -q 'Cipher is ECDHE-RSA-AES256-GCM-SHA384' <<<"$h"
    fi
    mstop "$n"
}

if [ -d "$T/vendor" ]; then
    tls_case vendor_tls $S; P_DEFAULT=$PERCPU
    tls_case vendor_rseq0 $S GLIBC_TUNABLES=glibc.pthread.rseq=0; P_TUN=$PERCPU
    for c in "$T"/vendor/share/openssl3/fips140-*; do
        [ -d "$c" ] || continue; f=$(basename "$c")
        # shellcheck disable=SC2046
        fips_case "vendor_${f//-/}" $S "$S/share/openssl3/$f/openssl.cnf" "$S/lib/ossl-modules/$f" $(cnf_envs "$c/openssl.cnf" $S)
    done
fi
tls_case ours_tls $D; [ -d "$T/vendor" ] || P_DEFAULT=$PERCPU
[ -d "$T/vendor" ] || { tls_case ours_rseq0 $D GLIBC_TUNABLES=glibc.pthread.rseq=0; P_TUN=$PERCPU; }
fips_case ours_fips $D /work/verify/ours-fips.cnf $D/lib/ossl-modules

res perCPU INFO "default=$P_DEFAULT with_tunable=$P_TUN (glibc $glibc, kernel $kernel)"
if [ $KERNEL_GUARD = 1 ]; then
    chk rseq0_guard "tunable on guarded kernel -> mongod refuses to start" test "$P_TUN" = guard
else
    chk rseq0_percpu "tunable turns per-CPU caches on" test "$P_TUN" = True
fi

# no FIPS provider reachable: --tlsFIPSMode must refuse to start
R=$D; [ -d "$T/vendor" ] && R=$S
if mstart nofips OPENSSL_CONF=/dev/null OPENSSL_MODULES=/poc/nomods LD_LIBRARY_PATH="$(lp $R)" -- --tlsFIPSMode; then
    res nofips_refused FAIL "started without a FIPS provider"; mstop nofips
else
    l=$(mlog nofips)
    chk nofips_refused "$(grep -oE '"id":(7585801|12257600),[^}]*' <<<"$l" | head -1 | cut -c1-120)" grep -qE '"id":(7585801|12257600)' <<<"$l"
fi
echo ONE_DONE
