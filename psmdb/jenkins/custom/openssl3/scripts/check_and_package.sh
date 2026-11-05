#!/bin/bash
# Runs in the build container after build_psmdb.sh. Checks the binaries (fails the job on any
# mismatch), then writes everything that goes to RepoCI into $WORK/out:
#   <name>.tar.gz + .sha256                 mongod/mongos/perconadecrypt/mongobridge, stripped
#   <name>-runtime-libs.tar.gz + .sha256    our rebuilt libs in the customer's layout + README
#   <name>.manifest.json                    versions, commit, NEEDED, min OpenSSL at runtime, hashes
#   <name>.sbom.cdx.json, <name>-runtime-libs.sbom.cdx.json
#
# env: OPENSSL_VERSION, PROFILE, ARCH, BUILD_URL (optional), WORK (default /work)
set -euo pipefail
: "${OPENSSL_VERSION:?}" "${PROFILE:?}" "${ARCH:?}"
WORK=${WORK:-/work}
HERE=$(cd "$(dirname "$0")" && pwd)
RT=$WORK/rt
SRC=$WORK/src/percona-server-mongodb
BIN=$SRC/bazel-bin/install-dist-test/bin
# shellcheck disable=SC1090
source "$PROFILE"
# shellcheck disable=SC1091
source "$WORK/psmdb-build.env"

fail=0
ok()  { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

NEEDED=$(readelf -d $BIN/mongod | awk '/NEEDED/{print $NF}' | tr -d '[]' | sort | xargs)
[ "$NEEDED" = "$EXPECTED_NEEDED" ] && ok "NEEDED as expected" || { bad "NEEDED differs"; echo " got:      $NEEDED"; echo " expected: $EXPECTED_NEEDED"; }

readelf -d $BIN/mongod | grep -q 'so\.1\.1' && bad "mongod needs OpenSSL 1.1" || ok "no OpenSSL 1.1 in mongod"
for f in $(find "$RT" -name '*.so*' -type f); do
    readelf -d "$f" 2>/dev/null | grep -q 'lib\(ssl\|crypto\)\.so\.1\.1' && bad "$f needs OpenSSL 1.1"
done

# symbol versions: newest glibc needed (must stay within the RHEL 8 baseline) and the oldest
# OpenSSL that can run this binary (the build headers decide it, e.g. 3.5 headers -> OPENSSL_3.4.0)
VERS=$(readelf -V $BIN/mongod | grep -oE 'Name: (GLIBC|OPENSSL)_[0-9.]+' | sed 's/Name: //' | sort -uV)
GLIBC_NEED=$(grep '^GLIBC_' <<<"$VERS" | sed 's/GLIBC_//' | sort -V | tail -1)
MIN_OPENSSL=$(grep '^OPENSSL_' <<<"$VERS" | sed 's/OPENSSL_//' | sort -V | tail -1)
[ "$(printf '%s\n%s\n' "$GLIBC_NEED" "$MAX_GLIBC" | sort -V | tail -1)" = "$MAX_GLIBC" ] \
    && ok "glibc symbols up to $GLIBC_NEED (limit $MAX_GLIBC)" || bad "needs glibc $GLIBC_NEED > $MAX_GLIBC"
echo "INFO: minimal OpenSSL at runtime: $MIN_OPENSSL"

LDD=$(LD_LIBRARY_PATH=$RT/opt/mongo/openssl3/lib:$RT/lib ldd $BIN/mongod)
echo "$LDD"
grep -q 'not found' <<<"$LDD" && bad "unresolved libs with runtime-libs" || ok "all libs resolved with runtime-libs"
n=$(grep -c " $RT/" <<<"$LDD" || true)
[ "$n" -eq "$EXPECTED_LAYOUT_LIBS" ] && ok "$n libs from runtime-libs" || bad "$n libs from runtime-libs, expected $EXPECTED_LAYOUT_LIBS"
V=$(LD_LIBRARY_PATH=$RT/opt/mongo/openssl3/lib:$RT/lib $BIN/mongod --version)
grep -q "OpenSSL $OPENSSL_VERSION " <<<"$V" && ok "runtime OpenSSL $OPENSSL_VERSION" || bad "mongod --version: $(grep -i openssl <<<"$V")"

[ $fail -eq 0 ] || { echo "artifact checks failed"; exit 1; }

# ---- package
NAME=percona-server-mongodb-${PSMDB_VERSION}-${ARCH}.glibc${MAX_GLIBC}-openssl${OPENSSL_VERSION}
LIBS=${NAME}-runtime-libs
OUT=$WORK/out
rm -rf "$OUT" "$WORK/pkg" && mkdir -p "$OUT" "$WORK/pkg/$NAME/bin" "$WORK/pkg/$LIBS"
for t in mongod mongos perconadecrypt mongobridge; do
    strip --strip-debug -o "$WORK/pkg/$NAME/bin/$t" "$BIN/$t"
done
cp "$SRC"/LICENSE-Community.txt "$SRC"/README* "$WORK/pkg/$NAME/" 2>/dev/null || true

cp -a "$RT/lib" "$WORK/pkg/$LIBS/"
mkdir -p "$WORK/pkg/$LIBS/opt/mongo/openssl3" "$WORK/pkg/$LIBS/bin"
cp -a "$RT/opt/mongo/openssl3/lib" "$WORK/pkg/$LIBS/opt/mongo/openssl3/"
cp -a /opt/ossl/bin/openssl "$WORK/pkg/$LIBS/bin/"          # needed for fipsinstall on the target
find "$WORK/pkg/$LIBS" \( -name '*.a' -o -name '*.la' -o -name pkgconfig \) -prune -exec rm -rf {} +
sed -e "s/@OPENSSL_VERSION@/$OPENSSL_VERSION/g" -e "s/@MIN_OPENSSL@/$MIN_OPENSSL/g" \
    -e "s/@NAME@/$NAME/g" "$HERE/README-runtime-libs.md" > "$WORK/pkg/$LIBS/README.md"

cd "$WORK/pkg"
tar --owner=0 --group=0 -czf "$OUT/$NAME.tar.gz" "$NAME"
tar --owner=0 --group=0 -czf "$OUT/$LIBS.tar.gz" "$LIBS"
cd "$OUT"
sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256"
sha256sum "$LIBS.tar.gz" > "$LIBS.tar.gz.sha256"

python3 "$HERE/make_manifest_sbom.py" \
    --name "$NAME" --libs "$LIBS" --out "$OUT" \
    --psmdb-version "$PSMDB_VERSION" --commit "$PSMDB_COMMIT" --arch "$ARCH" \
    --openssl "$OPENSSL_VERSION" --min-openssl "$MIN_OPENSSL" --glibc "$GLIBC_NEED" \
    --needed "$NEEDED" --deps "$WORK/deps-versions.txt" --profile "$PROFILE_NAME" \
    --source-sbom "$SRC/sbom.json" --build-url "${BUILD_URL:-}"
ls -la "$OUT"
echo PACKAGE_DONE
