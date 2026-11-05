#!/usr/bin/env python3
"""Manifest + CycloneDX 1.5 SBOMs for the openssl3 tarballs.

The SBOMs sit next to the tarballs, not inside: each one records the sha256 of the exact
tarball it describes, which can't be done from inside that tarball.
"""
import argparse
import datetime
import hashlib
import json
import os
import uuid

DEP_URLS = {
    "openssl": "https://github.com/openssl/openssl/releases/download/openssl-{v}/openssl-{v}.tar.gz",
    "zlib": "https://www.zlib.net/fossils/zlib-{v}.tar.gz",
    "c-ares": "https://github.com/c-ares/c-ares/releases/download/v{v}/c-ares-{v}.tar.gz",
    "krb5": "https://kerberos.org/dist/krb5/{mm}/krb5-{v}.tar.gz",
    "cyrus-sasl": "https://github.com/cyrusimap/cyrus-sasl/releases/download/cyrus-sasl-{v}/cyrus-sasl-{v}.tar.gz",
    "openldap": "https://www.openldap.org/software/download/OpenLDAP/openldap-release/openldap-{v}.tgz",
    "curl": "https://curl.se/download/curl-{v}.tar.xz",
}
LICENSES = {"openssl": "Apache-2.0", "zlib": "Zlib", "c-ares": "MIT", "krb5": "MIT",
            "cyrus-sasl": "BSD-4-Clause-UC", "openldap": "OLDAP-2.8", "curl": "curl"}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def dep_component(name, version, src_sha, bundled):
    url = DEP_URLS[name].format(v=version, mm=version.rsplit(".", 1)[0])
    return {
        "type": "library", "name": name, "version": version,
        "bom-ref": f"pkg:generic/{name}@{version}",
        "purl": f"pkg:generic/{name}@{version}?download_url={url}",
        "licenses": [{"license": {"id": LICENSES[name]}}],
        "externalReferences": [{"type": "source-distribution", "url": url,
                                "hashes": [{"alg": "SHA-256", "content": src_sha}]}],
        "properties": [{"name": "percona:bundled", "value": str(bundled).lower()}],
    }


def bom(component, components, deps):
    return {
        "bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1,
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "metadata": {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "lifecycles": [{"phase": "build"}],
            "supplier": {"name": "Percona LLC", "url": ["https://percona.com"]},
            "component": component,
        },
        "components": components,
        "dependencies": deps,
    }


def main():
    p = argparse.ArgumentParser()
    for a in ("name", "libs", "out", "psmdb-version", "commit", "arch", "openssl", "min-openssl",
              "glibc", "needed", "deps", "profile", "source-sbom", "build-url"):
        p.add_argument("--" + a, required=a != "build-url", default="")
    o = p.parse_args()

    deps = {}
    with open(o.deps) as f:
        for line in f:
            n, v, s = line.split()
            deps[n] = (v, s)

    tgz = os.path.join(o.out, o.name + ".tar.gz")
    libs_tgz = os.path.join(o.out, o.libs + ".tar.gz")
    manifest = {
        "product": "percona-server-mongodb",
        "version": o.psmdb_version,
        "commit": o.commit,
        "arch": o.arch,
        "build_baseline": "Oracle Linux 8 (RHEL 8 compatible)",
        "max_glibc_symbol": o.glibc,
        "openssl_built_against": o.openssl,
        "openssl_min_runtime": o.min_openssl,
        "openssl_bundled": False,
        "mongod_needed": o.needed.split(),
        "runtime_libs_profile": o.profile,
        "runtime_libs": {n: {"version": v, "source_sha256": s} for n, (v, s) in deps.items()},
        "artifacts": {os.path.basename(tgz): sha256(tgz), os.path.basename(libs_tgz): sha256(libs_tgz)},
        "build_url": o.build_url,
        "built_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    with open(os.path.join(o.out, o.name + ".manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    # mongod tarball: PSMDB's own source SBOM components + OpenSSL as a required, not bundled, dep
    psmdb_ref = f"pkg:github/percona/percona-server-mongodb@{o.psmdb_version}"
    src_components = []
    if os.path.exists(o.source_sbom):
        with open(o.source_sbom) as f:
            src_components = json.load(f).get("components", [])
    ossl = dep_component("openssl", *deps["openssl"], bundled=False)
    ossl["scope"] = "required"
    main_component = {
        "type": "application", "name": "percona-server-mongodb", "version": o.psmdb_version,
        "bom-ref": psmdb_ref, "purl": psmdb_ref,
        "licenses": [{"license": {"id": "SSPL-1.0"}}],
        "hashes": [{"alg": "SHA-256", "content": manifest["artifacts"][os.path.basename(tgz)]}],
        "properties": [{"name": "percona:commit", "value": o.commit},
                       {"name": "percona:openssl_min_runtime", "value": o.min_openssl}],
    }
    with open(os.path.join(o.out, o.name + ".sbom.cdx.json"), "w") as f:
        json.dump(bom(main_component, src_components + [ossl],
                      [{"ref": psmdb_ref, "dependsOn": [ossl["bom-ref"]]}]), f, indent=2)

    # runtime-libs tarball: every rebuilt lib, all bundled
    libs_ref = f"pkg:generic/{o.libs}"
    comps = [dep_component(n, v, s, bundled=True) for n, (v, s) in deps.items()]
    libs_component = {
        "type": "library", "name": o.libs, "version": o.psmdb_version, "bom-ref": libs_ref,
        "hashes": [{"alg": "SHA-256", "content": manifest["artifacts"][os.path.basename(libs_tgz)]}],
    }
    with open(os.path.join(o.out, o.libs + ".sbom.cdx.json"), "w") as f:
        json.dump(bom(libs_component, comps, [{"ref": libs_ref, "dependsOn": [c["bom-ref"] for c in comps]}]),
                  f, indent=2)


if __name__ == "__main__":
    main()
