#!/bin/bash
# Prepares the test dir $T on the agent and the client container (oscheck-helper, oraclelinux:8,
# network host): pymongo, test certs, fipsmodule.cnf for our provider, client.py.
# The openssl CLI comes from the runtime-libs tarball (bin/openssl), so nothing is compiled here.
#
# Expects in $T: pkg/<psmdb dir>, rt/ (runtime-libs unpacked), optionally vendor/ (customer bundle).
# env: T, HELPER (default oscheck-helper)
set -euxo pipefail
: "${T:?}"
HELPER=${HELPER:-oscheck-helper}

docker rm -f "$HELPER" >/dev/null 2>&1 || true
docker pull -q oraclelinux:8
docker run -d --name "$HELPER" --network host -v "$T":/work oraclelinux:8 sleep infinity
docker exec "$HELPER" bash -c 'yum -y -q install python3.11 python3.11-pip >/dev/null && python3.11 -m pip install -q pymongo'

docker exec -i "$HELPER" bash -euxo pipefail <<'EOS'
O="env LD_LIBRARY_PATH=/work/rt/lib /work/rt/bin/openssl"
V=/work/verify
rm -rf $V && mkdir -p $V/certs
$O version

# fipsinstall runs the provider self-tests and writes the MAC of this exact fips.so
$O fipsinstall -module /work/rt/lib/ossl-modules/fips.so -out $V/fipsmodule.cnf
cat > $V/ours-fips.cnf <<'EOF'
config_diagnostics = 1
openssl_conf = openssl_init
.include /work/verify/fipsmodule.cnf

[openssl_init]
providers = provider_sect
alg_section = algorithm_sect

[provider_sect]
fips = fips_sect
base = base_sect

[base_sect]
activate = 1

[algorithm_sect]
default_properties = fips=yes
EOF

cd $V/certs
$O req -x509 -newkey rsa:2048 -sha256 -nodes -days 30 -subj "/CN=oscheck-ca" -keyout ca.key -out ca.pem 2>/dev/null
$O req -newkey rsa:2048 -sha256 -nodes -subj "/CN=localhost" -keyout srv.key -out srv.csr 2>/dev/null
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > ext.cnf
$O x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 -sha256 -extfile ext.cnf -out srv.crt 2>/dev/null
cat srv.key srv.crt > server.pem
chmod 644 ./*

# app-like client: single-node replset over TLS, CRUD, runtime OpenSSL and tcmalloc mode
cat > $V/client.py <<'EOF'
import sys, time, pymongo
port = int(sys.argv[1])
c = pymongo.MongoClient(f"mongodb://localhost:{port}/?tls=true&tlsCAFile=/work/verify/certs/ca.pem&directConnection=true",
                        serverSelectionTimeoutMS=20000)
c.admin.command("ping")
c.admin.command("replSetInitiate", {"_id": "kv", "members": [{"_id": 0, "host": f"localhost:{port}"}]})
for _ in range(60):
    if c.admin.command("hello").get("isWritablePrimary"): break
    time.sleep(1)
else:
    sys.exit("not primary after 60s")
col = c.oscheck.coll
col.insert_one({"_key": "a", "v": 1}); col.update_one({"_key": "a"}, {"$set": {"v": 2}})
assert col.find_one({"_key": "a"})["v"] == 2; col.delete_one({"_key": "a"})
assert col.count_documents({}) == 0
bi = c.admin.command("buildInfo")
ss = c.admin.command({"serverStatus": 1, "tcmalloc": 1})
print("OK", "openssl=" + bi.get("openssl", {}).get("running", "?").replace(" ", "_"),
      "perCPU=" + str(ss["tcmalloc"].get("usingPerCPUCaches")))
EOF
EOS
echo HELPER_DONE
