#!/bin/bash
# Runs in a fresh oraclelinux:8 container, after psmdb_builder.sh --install_deps=1.
# Builds OpenSSL (enable-fips, with zlib) and the runtime libs of the profile, in the customer's layout:
#   $RT/lib                    OpenSSL, curl, OpenLDAP, c-ares, zlib, ossl-modules/
#   $RT/opt/mongo/openssl3/lib krb5, cyrus-sasl (+ sasl2/ plugins)
# OpenSSL dev files go to $OSSL, that's what MONGO_OPENSSL_ROOT points to.
#
# env: OPENSSL_VERSION, OPENSSL_SHA256 (empty = take the .sha256 published with the release),
#      PROFILE (path to profiles/*.env), WORK (default /work)
set -Eeuxo pipefail
: "${OPENSSL_VERSION:?}" "${PROFILE:?}"
WORK=${WORK:-/work}
OSSL=/opt/ossl
RT=$WORK/rt
M=$RT/opt/mongo/openssl3
J=$(nproc)
# shellcheck disable=SC1090
source "$PROFILE"

# tools the deps need on top of psmdb_builder's list (krb5 wants yacc, sasl/ldap autotools bits)
yum -y install bison flex libtool autoconf automake perl-core binutils file wget xz
# mongod must not see the system OpenSSL 1.1 headers; fail loudly instead of silently linking 1.1
if rpm -q openssl-devel; then rpm -e --nodeps openssl-devel; fi

rm -rf "$RT" "$OSSL" && mkdir -p "$RT/lib" "$M/lib" "$WORK/deps-src"
cd "$WORK/deps-src"

fetch() { # url sha256
    local f; f=$(basename "$1")
    wget -q -O "$f" "$1"
    echo "$2  $f" | sha256sum -c -
    tar xf "$f"
}

# zlib first: OpenSSL links it (libz.so.1 in NEEDED, as in the customer's build)
fetch https://www.zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz "$ZLIB_SHA256"
(cd zlib-${ZLIB_VERSION} && ./configure --prefix="$RT" && make -j"$J" && make install)

if [ -z "${OPENSSL_SHA256:-}" ]; then
    OPENSSL_SHA256=$(wget -q -O - https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz.sha256 | awk '{print $1}')
fi
fetch https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz "$OPENSSL_SHA256"
(
    cd openssl-${OPENSSL_VERSION}
    ./Configure --prefix=$OSSL --openssldir=$OSSL/ssl --libdir=lib shared enable-fips \
        zlib --with-zlib-include="$RT/include" --with-zlib-lib="$RT/lib"
    make -j"$J"
    make install_sw install_ssldirs install_fips
)
cp -a $OSSL/lib/libssl.so* $OSSL/lib/libcrypto.so* "$RT/lib/"
cp -a $OSSL/lib/ossl-modules "$RT/lib/"

export CPPFLAGS="-I$RT/include -I$M/include -I$OSSL/include"
export LDFLAGS="-L$RT/lib -L$M/lib -L$OSSL/lib -Wl,-rpath-link,$RT/lib -Wl,-rpath-link,$M/lib -Wl,-rpath-link,$OSSL/lib"
export PKG_CONFIG_PATH=$RT/lib/pkgconfig:$M/lib/pkgconfig:$OSSL/lib/pkgconfig
export LD_LIBRARY_PATH=$M/lib:$RT/lib:$OSSL/lib
export CFLAGS="-O2 -g -Wno-deprecated-declarations"

fetch https://github.com/c-ares/c-ares/releases/download/v${CARES_VERSION}/c-ares-${CARES_VERSION}.tar.gz "$CARES_SHA256"
(cd c-ares-${CARES_VERSION} && ./configure --prefix="$RT" --libdir="$RT/lib" --disable-static --disable-tests \
    && make -j"$J" && make install)

# krb5: builtin crypto, only the k5tls plugin uses OpenSSL, no keyutils
fetch https://kerberos.org/dist/krb5/${KRB5_VERSION%.*}/krb5-${KRB5_VERSION}.tar.gz "$KRB5_SHA256"
(cd krb5-${KRB5_VERSION}/src && ./configure --prefix="$M" --libdir="$M/lib" --disable-rpath --disable-static \
    --with-crypto-impl=builtin --with-tls-impl=openssl --without-keyutils --without-system-verto \
    && make -j"$J" && make install)

# cyrus-sasl: only scram + otp plugins
fetch https://github.com/cyrusimap/cyrus-sasl/releases/download/cyrus-sasl-${SASL_VERSION}/cyrus-sasl-${SASL_VERSION}.tar.gz "$SASL_SHA256"
(cd cyrus-sasl-${SASL_VERSION} && ./configure --prefix="$M" --libdir="$M/lib" --with-plugindir="$M/lib/sasl2" \
    --with-openssl=$OSSL --with-dblib=none --disable-static --disable-sample \
    --disable-gssapi --disable-plain --disable-anon --disable-cram --disable-digest \
    --disable-login --disable-ntlm --disable-srp --enable-scram --enable-otp \
    && make -j"$J" && make install)

# openldap: client libs only, OpenSSL TLS, no SASL
fetch https://www.openldap.org/software/download/OpenLDAP/openldap-release/openldap-${OPENLDAP_VERSION}.tgz "$OPENLDAP_SHA256"
(cd openldap-${OPENLDAP_VERSION} && ./configure --prefix="$RT" --libdir="$RT/lib" --disable-slapd --disable-static \
    --with-tls=openssl --without-cyrus-sasl \
    && make depend && make -C include && make -C libraries -j"$J" && make -C include install && make -C libraries install)

# curl: OpenSSL + c-ares + zlib, versioned symbols (CURL_OPENSSL_4), everything else off
fetch https://curl.se/download/curl-${CURL_VERSION}.tar.xz "$CURL_SHA256"
(cd curl-${CURL_VERSION} && ./configure --prefix="$RT" --libdir="$RT/lib" --disable-static --enable-versioned-symbols \
    --with-openssl=$OSSL --enable-ares="$RT" --with-zlib="$RT" \
    --without-gssapi --without-libpsl --without-brotli --without-zstd --without-nghttp2 \
    --without-nghttp3 --without-ngtcp2 --without-libidn2 --without-libssh --without-libssh2 \
    --without-librtmp --disable-ldap --disable-ldaps --disable-docs \
    && make -j"$J" && make install)

# record exact source hashes for the manifest/SBOM
{
    echo "openssl ${OPENSSL_VERSION} ${OPENSSL_SHA256}"
    echo "zlib ${ZLIB_VERSION} ${ZLIB_SHA256}"
    echo "c-ares ${CARES_VERSION} ${CARES_SHA256}"
    echo "krb5 ${KRB5_VERSION} ${KRB5_SHA256}"
    echo "cyrus-sasl ${SASL_VERSION} ${SASL_SHA256}"
    echo "openldap ${OPENLDAP_VERSION} ${OPENLDAP_SHA256}"
    echo "curl ${CURL_VERSION} ${CURL_SHA256}"
} > "$WORK/deps-versions.txt"
LD_LIBRARY_PATH=$OSSL/lib:$RT/lib $OSSL/bin/openssl version -a
echo DEPS_DONE
