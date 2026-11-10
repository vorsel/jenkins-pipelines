#!/bin/bash
# Runs in a fresh oraclelinux:8 container, after psmdb_builder.sh --install_deps=1.
# Builds OpenSSL (enable-fips, with zlib) and the runtime libs of the profile, in the customer's layout:
#   $RT/lib                    OpenSSL, curl, OpenLDAP, c-ares, zlib, ossl-modules/
#   $RT/opt/mongo/openssl3/lib krb5, cyrus-sasl (+ sasl2/ plugins)
# Everything is configured for $RUNTIME_PREFIX (a symlink to $RT here), so paths compiled into
# the libs (sasl and krb5 plugin dirs) are the install dir, not the workspace.
# OpenSSL dev files go to $OSSL, that's what MONGO_OPENSSL_ROOT points to.
#
# env: OPENSSL_VERSION, OPENSSL_SHA256 (empty = take the .sha256 published with the release),
#      PROFILE (path to profiles/*.env), WORK (default /work)
set -Eeuxo pipefail
: "${OPENSSL_VERSION:?}" "${PROFILE:?}"
WORK=${WORK:-/work}
OSSL=/opt/ossl
RT=$WORK/rt
J=$(nproc)
# shellcheck disable=SC1090
source "$PROFILE"
P=$RUNTIME_PREFIX
M=$P/opt/mongo/openssl3

# tools the deps need on top of psmdb_builder's list (krb5 wants yacc, sasl/ldap autotools bits)
yum -y install bison flex libtool autoconf automake perl-core binutils file wget xz
# mongod must not see the system OpenSSL 1.1 headers; fail loudly instead of silently linking 1.1
if rpm -q openssl-devel; then rpm -e --nodeps openssl-devel; fi

rm -rf "$RT" "$OSSL" "$P" && mkdir -p "$RT/lib" "$RT/opt/mongo/openssl3/lib" "$WORK/deps-src"
ln -s "$RT" "$P"
cd "$WORK/deps-src"

fetch() { # url sha256
    local f; f=$(basename "$1")
    wget -q -O "$f" "$1"
    echo "$2  $f" | sha256sum -c -
    tar xf "$f"
}
# libtool puts the libdir into DT_RPATH, which is searched before LD_LIBRARY_PATH
norpath() {
    sed -i 's|^hardcode_libdir_flag_spec=.*|hardcode_libdir_flag_spec=""|; s|^runpath_var=LD_RUN_PATH|runpath_var=NO_RUNPATH|' libtool
}

# zlib first: OpenSSL links it (libz.so.1 in NEEDED, as in the customer's build)
fetch https://www.zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz "$ZLIB_SHA256"
(cd zlib-${ZLIB_VERSION} && ./configure --prefix="$P" && make -j"$J" && make install)

if [ -z "${OPENSSL_SHA256:-}" ]; then
    OPENSSL_SHA256=$(wget -q -O - https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz.sha256 | awk '{print $1}')
fi
fetch https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz "$OPENSSL_SHA256"
(
    cd openssl-${OPENSSL_VERSION}
    ./Configure --prefix=$OSSL --openssldir=$OSSL/ssl --libdir=lib shared enable-fips \
        zlib --with-zlib-include="$P/include" --with-zlib-lib="$P/lib"
    make -j"$J"
    make install_sw install_ssldirs install_fips
)
cp -a $OSSL/lib/libssl.so* $OSSL/lib/libcrypto.so* "$RT/lib/"
cp -a $OSSL/lib/ossl-modules "$RT/lib/"

export CPPFLAGS="-I$P/include -I$M/include -I$OSSL/include"
export LDFLAGS="-L$P/lib -L$M/lib -L$OSSL/lib -Wl,-rpath-link,$P/lib -Wl,-rpath-link,$M/lib -Wl,-rpath-link,$OSSL/lib"
export PKG_CONFIG_PATH=$P/lib/pkgconfig:$M/lib/pkgconfig:$OSSL/lib/pkgconfig
export LD_LIBRARY_PATH=$M/lib:$P/lib:$OSSL/lib
export CFLAGS="-O2 -g -Wno-deprecated-declarations"

fetch https://github.com/c-ares/c-ares/releases/download/v${CARES_VERSION}/c-ares-${CARES_VERSION}.tar.gz "$CARES_SHA256"
(cd c-ares-${CARES_VERSION} && ./configure --prefix="$P" --libdir="$P/lib" --disable-static --disable-tests \
    && make -j"$J" && make install)

# krb5: builtin crypto, only the k5tls plugin uses OpenSSL, no keyutils
fetch https://kerberos.org/dist/krb5/${KRB5_VERSION%.*}/krb5-${KRB5_VERSION}.tar.gz "$KRB5_SHA256"
(cd krb5-${KRB5_VERSION}/src && ./configure --prefix="$M" --libdir="$M/lib" --disable-rpath --disable-static \
    --with-crypto-impl=builtin --with-tls-impl=openssl --without-keyutils --without-system-verto \
    && make -j"$J" && make install)

# cyrus-sasl: scram + otp as in the customer's bundle, plus what mongod needs as a SASL server:
# gssapi (Kerberos) and plain (saslauthd). runpath_switch=none: no DT_RPATH to the OpenSSL dir
fetch https://github.com/cyrusimap/cyrus-sasl/releases/download/cyrus-sasl-${SASL_VERSION}/cyrus-sasl-${SASL_VERSION}.tar.gz "$SASL_SHA256"
(cd cyrus-sasl-${SASL_VERSION} && andrew_cv_runpath_switch=none ./configure --prefix="$M" --libdir="$M/lib" \
    --with-plugindir="$M/lib/sasl2" --with-configdir="$M/lib/sasl2:/etc/sasl2" --with-saslauthd=/var/run/saslauthd \
    --with-openssl=$OSSL --with-dblib=none --disable-static --disable-sample \
    --enable-gssapi="$M" --with-gss_impl=mit --enable-plain --enable-scram --enable-otp \
    --disable-anon --disable-cram --disable-digest --disable-login --disable-ntlm --disable-srp \
    && norpath && make -j"$J" && make install)

# openldap: client libs only, OpenSSL TLS, no SASL; ldap.conf from /etc/openldap as the distro one
fetch https://www.openldap.org/software/download/OpenLDAP/openldap-release/openldap-${OPENLDAP_VERSION}.tgz "$OPENLDAP_SHA256"
(cd openldap-${OPENLDAP_VERSION} && ./configure --prefix="$P" --libdir="$P/lib" --sysconfdir=/etc --localstatedir=/var \
    --disable-slapd --disable-static --with-tls=openssl --without-cyrus-sasl \
    && norpath && make depend && make -C include && make -C libraries -j"$J" && make -C include install && make -C libraries install)

# curl: OpenSSL + c-ares + zlib, versioned symbols (CURL_OPENSSL_4), everything else off
fetch https://curl.se/download/curl-${CURL_VERSION}.tar.xz "$CURL_SHA256"
(cd curl-${CURL_VERSION} && ./configure --prefix="$P" --libdir="$P/lib" --disable-static --enable-versioned-symbols \
    --with-openssl=$OSSL --enable-ares="$P" --with-zlib="$P" \
    --without-gssapi --without-libpsl --without-brotli --without-zstd --without-nghttp2 \
    --without-nghttp3 --without-ngtcp2 --without-libidn2 --without-libssh --without-libssh2 \
    --without-librtmp --disable-ldap --disable-ldaps --disable-docs \
    && norpath && make -j"$J" && make install)

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
