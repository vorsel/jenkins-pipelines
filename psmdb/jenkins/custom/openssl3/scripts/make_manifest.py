#!/usr/bin/env python3
"""manifest.json for the openssl3 tarballs.

Holds everything make_sbom.py needs, so SBOMs can be redone later without a rebuild.
"""
import argparse
import datetime
import hashlib
import json
import os


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser()
    for a in ("name", "libs", "out", "psmdb-version", "commit", "arch", "openssl", "min-openssl",
              "glibc", "needed", "deps", "profile", "build-url"):
        p.add_argument("--" + a, required=a != "build-url", default="")
    o = p.parse_args()

    deps = {}
    with open(o.deps) as f:
        for line in f:
            n, v, s = line.split()
            deps[n] = {"version": v, "source_sha256": s}

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
        "runtime_libs": deps,
        "artifacts": {os.path.basename(tgz): sha256(tgz), os.path.basename(libs_tgz): sha256(libs_tgz)},
        "build_url": o.build_url,
        "built_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    with open(os.path.join(o.out, o.name + ".manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)


if __name__ == "__main__":
    main()
