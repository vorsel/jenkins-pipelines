#!/bin/bash
# Runs in the same oraclelinux:8 container right after build_runtime_deps.sh.
# Bazel build like psmdb_builder.sh (same config/target), local only: RBE workers have no
# OpenSSL 3 under MONGO_OPENSSL_ROOT, so remote execution can't be used here.
#
# env: PSMDB_REPO, PSMDB_TAG (e.g. psmdb-8.0.34-15), WORK (default /work)
set -euxo pipefail
: "${PSMDB_REPO:?}" "${PSMDB_TAG:?}"
WORK=${WORK:-/work}
SRC=$WORK/src/percona-server-mongodb
export MONGO_OPENSSL_ROOT=/opt/ossl
export PATH=$HOME/.local/bin:$PATH

rm -rf "$SRC"
git clone --depth 1 --branch "$PSMDB_TAG" "$PSMDB_REPO" "$SRC"
cd "$SRC"
COMMIT=$(git rev-parse HEAD)
VERSION=${PSMDB_TAG#psmdb-}

# the hook came with SERVER-133644 (r8.0.34); without it Bazel links the system OpenSSL
if ! grep -q MONGO_OPENSSL_ROOT bazel/toolchains/cc/mongo_linux/mongo_toolchain.bzl; then
    echo "ERROR: $PSMDB_TAG has no MONGO_OPENSSL_ROOT support (needs 8.0.34+ or a backport of SERVER-133644)"
    exit 1
fi

# the enable scripts trip over set -u (MANPATH)
set +u
source /opt/rh/gcc-toolset-9/enable
source /opt/rh/gcc-toolset-11/enable
set -u

export CFLAGS="${CFLAGS:-} -fno-omit-frame-pointer"
export CXXFLAGS="${CFLAGS}"
export PORTABLE=1
export USE_SSE=1

python3 buildscripts/install_bazel.py
bazel build --config=psmdb_opt_release \
    --define=MONGO_VERSION="$VERSION" \
    --define=GIT_COMMIT_HASH="$COMMIT" \
    install-dist-test

printf 'PSMDB_VERSION=%s\nPSMDB_COMMIT=%s\n' "$VERSION" "$COMMIT" > "$WORK/psmdb-build.env"
echo BUILD_DONE
