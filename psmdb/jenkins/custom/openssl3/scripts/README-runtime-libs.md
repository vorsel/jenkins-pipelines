# Runtime libraries for @NAME@

Shared libraries that `mongod` from `@NAME@.tar.gz` needs besides glibc,
built from upstream sources against OpenSSL @OPENSSL_VERSION@ on a RHEL 8 baseline (glibc 2.28).
Use them if you don't ship your own builds of these libraries.

```
lib/                       libssl, libcrypto (OpenSSL @OPENSSL_VERSION@), libcurl, libldap, liblber, libcares, libz
lib/ossl-modules/          fips.so, legacy.so
opt/mongo/openssl3/lib/    libgssapi_krb5, libkrb5, libk5crypto, libkrb5support, libcom_err, libsasl2 (+ sasl2/ plugins)
bin/openssl                OpenSSL CLI, needed for `fipsinstall`
```

## Install

```bash
tar xzf @NAME@.tar.gz -C /opt
tar xzf @NAME@-runtime-libs.tar.gz -C /opt
L=/opt/@NAME@-runtime-libs
export LD_LIBRARY_PATH=$L/opt/mongo/openssl3/lib:$L/lib
/opt/@NAME@/bin/mongod --version        # must report OpenSSL @OPENSSL_VERSION@
```

`mongod` needs OpenSSL @MIN_OPENSSL@ or newer at runtime (symbol version `OPENSSL_@MIN_OPENSSL@`).

## FIPS mode

`fipsmodule.cnf` must be generated on the target host, because `fipsinstall` runs the module self-tests there:

```bash
LD_LIBRARY_PATH=$L/lib $L/bin/openssl fipsinstall -module $L/lib/ossl-modules/fips.so -out $L/fipsmodule.cnf
```

Then use an `openssl.cnf` that includes this file, activates the `fips` and `base` providers,
and sets `default_properties = fips=yes`. Start mongod with:

```bash
export OPENSSL_CONF=/path/to/openssl.cnf OPENSSL_MODULES=$L/lib/ossl-modules
mongod --tlsFIPSMode ...
```

The `fips.so` here is built from OpenSSL @OPENSSL_VERSION@ source. It is a validated module
only if this exact version is listed in the OpenSSL FIPS 140 certificate.
For compliance, point `OPENSSL_MODULES` at your validated FIPS provider instead.

## tcmalloc and glibc rseq

On glibc that registers rseq (2.35+, and 2.34 on RHEL 9 / Amazon Linux 2023), tcmalloc per-CPU caches
are disabled unless mongod runs with:

```bash
export GLIBC_TUNABLES=glibc.pthread.rseq=0
```

This setting has no effect on glibc 2.28.
On Linux kernels 6.19.0 – 7.0.13, mongod refuses to start when per-CPU caches are active
(SERVER-121912). Don't set the variable on these kernels.
On RHEL 8 hosts, per-CPU caches are always active, so mongod can't run on those kernels at all.
