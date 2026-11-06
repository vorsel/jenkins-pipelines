#!/usr/bin/env python3
"""CycloneDX 1.5 SBOMs for the openssl3 tarballs, from manifest.json + PSMDB's sbom.json.

Needs only the manifest, so SBOMs can be redone for an old build without rebuilding it.
The SBOMs sit next to the tarballs, not inside: each one records the sha256 of the exact
tarball it describes, which can't be done from inside that tarball.
Runs on python 3.6 (OL8 platform-python).
"""
import argparse
import datetime
import json
import os
import re
import urllib.request
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
# NVD vendor:product; scanners match C libs only by CPE (without it grype misses curl and krb5)
CPES = {"openssl": "openssl:openssl", "zlib": "zlib:zlib", "c-ares": "c-ares:c-ares",
        "krb5": "mit:kerberos_5", "cyrus-sasl": "cyrusimap:cyrus-sasl",
        "openldap": "openldap:openldap", "curl": "haxx:curl"}
PERCONA = {"name": "Percona LLC", "url": ["https://percona.com"]}


def cpe(vendor_product, version):
    return f"cpe:2.3:a:{vendor_product}:{version}:*:*:*:*:*:*:*"


def dep_component(name, version, src_sha, bundled):
    url = DEP_URLS[name].format(v=version, mm=version.rsplit(".", 1)[0])
    return {
        "type": "library", "name": name, "version": version,
        "bom-ref": f"pkg:generic/{name}@{version}",
        "purl": f"pkg:generic/{name}@{version}?download_url={url}",
        "cpe": cpe(CPES[name], version),
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
            "supplier": PERCONA,
            "component": component,
        },
        "components": components,
        "dependencies": deps,
    }


def fetch_source_sbom(repo, commit):
    m = re.match(r"https://github\.com/([^/]+/[^/]+?)(\.git)?/?$", repo)
    if not m:
        raise SystemExit(f"not a github.com repo URL: {repo}")
    url = f"https://raw.githubusercontent.com/{m.group(1)}/{commit}/sbom.json"
    print("source SBOM:", url)
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--manifest", required=True)
    p.add_argument("--psmdb-repo", required=True, help="github URL; sbom.json is taken at the manifest commit")
    p.add_argument("--out", required=True)
    o = p.parse_args()

    with open(o.manifest) as f:
        man = json.load(f)
    tarballs = list(man["artifacts"])
    libs_tgz = next(t for t in tarballs if t.endswith("-runtime-libs.tar.gz"))
    tgz = next(t for t in tarballs if t != libs_tgz)
    version = man["version"]          # 8.0.34-15
    upstream = version.split("-")[0]  # 8.0.34
    deps = man["runtime_libs"]
    os.makedirs(o.out, exist_ok=True)

    # mongod tarball: PSMDB's source SBOM + OpenSSL as a required, not bundled, dep.
    # upstream sbom.json keeps the branch version (v8.0, cpe 8.0.*), which makes scanners report
    # every 8.0 CVE; pin mongo and PSMDB to this release
    src = fetch_source_sbom(o.psmdb_repo, man["commit"])
    psmdb_ref = f"pkg:github/percona/percona-server-mongodb@{version}"
    mongo_ref = f"pkg:github/mongodb/mongo@{upstream}"
    renames = {}
    src_psmdb = src.get("metadata", {}).get("component", {}).get("bom-ref")
    if src_psmdb:
        renames[src_psmdb] = psmdb_ref
    components = src.get("components", [])
    mongo = [c for c in components if c.get("purl", "").startswith("pkg:github/mongodb/mongo@")]
    if len(mongo) != 1:
        raise SystemExit(f"expected one mongodb/mongo component in sbom.json, got {len(mongo)}")
    renames[mongo[0]["bom-ref"]] = mongo_ref
    mongo[0].update({"version": upstream, "purl": mongo_ref, "bom-ref": mongo_ref,
                     "cpe": cpe("mongodb:mongodb", upstream)})

    graph = [{"ref": renames.get(d["ref"], d["ref"]),
              "dependsOn": [renames.get(r, r) for r in d.get("dependsOn", [])]}
             for d in src.get("dependencies", [])]
    ossl = dep_component("openssl", deps["openssl"]["version"], deps["openssl"]["source_sha256"],
                         bundled=False)
    ossl["scope"] = "required"
    top = next((d for d in graph if d["ref"] == psmdb_ref), None)
    if top is None:
        top = {"ref": psmdb_ref, "dependsOn": [mongo_ref]}
        graph.insert(0, top)
    top["dependsOn"].append(ossl["bom-ref"])
    graph.append({"ref": ossl["bom-ref"], "dependsOn": []})

    main_component = {
        "type": "application", "supplier": PERCONA, "name": "percona-server-mongodb",
        "version": version, "bom-ref": psmdb_ref, "purl": psmdb_ref,
        "cpe": cpe("percona:percona-server-mongodb", version),
        "licenses": [{"license": {"id": "SSPL-1.0"}}],
        "hashes": [{"alg": "SHA-256", "content": man["artifacts"][tgz]}],
        "properties": [{"name": "percona:commit", "value": man["commit"]},
                       {"name": "percona:openssl_min_runtime", "value": man["openssl_min_runtime"]}],
    }
    out = os.path.join(o.out, tgz[:-len(".tar.gz")] + ".sbom.cdx.json")
    with open(out, "w") as f:
        json.dump(bom(main_component, components + [ossl], graph), f, indent=2)
    print("wrote", out)

    # runtime-libs tarball: every rebuilt lib, all bundled
    libs_name = libs_tgz[:-len(".tar.gz")]
    libs_ref = f"pkg:generic/{libs_name}"
    comps = [dep_component(n, d["version"], d["source_sha256"], bundled=True) for n, d in deps.items()]
    libs_component = {
        "type": "library", "supplier": PERCONA, "name": libs_name, "version": version,
        "bom-ref": libs_ref,
        "hashes": [{"alg": "SHA-256", "content": man["artifacts"][libs_tgz]}],
    }
    out = os.path.join(o.out, libs_name + ".sbom.cdx.json")
    with open(out, "w") as f:
        json.dump(bom(libs_component, comps,
                      [{"ref": libs_ref, "dependsOn": [c["bom-ref"] for c in comps]}]
                      + [{"ref": c["bom-ref"], "dependsOn": []} for c in comps]), f, indent=2)
    print("wrote", out)


if __name__ == "__main__":
    main()
