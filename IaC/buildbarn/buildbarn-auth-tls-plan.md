# BuildBarn RBE — Authentication & TLS Plan

> Status: **Steps 1-2 DONE (all public endpoints now TLS); Steps 3-6 IN PROGRESS.**
> Last update: 2026-04-28.
> Tracking: PSMDB-2040 (jenkins-pipelines side); separate PSMDB ticket for
> the `percona-server-mongodb` `.bazelrc.psmdb` / `wrapper_hook.py` switch.
> Working domain: **`bb-psmdb.ddns.net`** (No-IP free DDNS).
> Public IP: **`95.217.242.120`** (Hetzner Floating IP, attached to the
> central VM; survives VM redeploy).
> TLS cert: Let's Encrypt via HTTP-01 standalone, ECDSA P-256, expires 2026-07-26.
> Cert path inside containers: `/etc/buildbarn/certs/{fullchain,privkey}.pem`
> (deploy-hook copies from `/etc/letsencrypt/live/.../` to
> `/var/lib/buildbarn/certs/`; mode 0644).
> Related docs: [`buildbarn-remote-execution-setup.md`](./buildbarn-remote-execution-setup.md), [`buildbarn-ondemand-scaler.md`](./buildbarn-ondemand-scaler.md), [`ondemand/README.md`](./ondemand/README.md).

This document captures the comprehensive plan for securing the public endpoints
of our BuildBarn Remote Build Execution cluster on Hetzner Cloud. It is the
result of a code-level audit of the upstream BuildBarn repositories (cloned to
`/Users/wiggin/percona/repos/buildbarnrepos/`):

- [`bb-storage`](https://github.com/buildbarn/bb-storage) — provides `pkg/grpc` and `pkg/http/server` reused by every other BB service.
- [`bb-remote-execution`](https://github.com/buildbarn/bb-remote-execution) — `bb_scheduler`, `bb_worker`, `bb_runner`.
- [`bb-browser`](https://github.com/buildbarn/bb-browser) — web UI.
- [`bb-deployments`](https://github.com/buildbarn/bb-deployments) — example configs (all use `allow{}`, not production-grade).
- [`bb-autoscaler`](https://github.com/buildbarn/bb-autoscaler) — Prometheus → AWS ASG / k8s scaler (not applicable to Hetzner).
- [`bb-adrs`](https://github.com/buildbarn/bb-adrs) — architectural notes.

Goal: **stop running publicly-exposed gRPC/HTTP without TLS or authentication**,
without adding heavy reverse-proxy infrastructure or writing custom Go middleware.

---

## TL;DR

- **Domain (interim)**: **`bb-psmdb.ddns.net`** (No-IP free tier). Single host,
  port-based fan-out (one cert covers everything since it's one hostname).
  Migration to a Percona-controlled domain is `sed` + new cert later.
- **Cert**: Let's Encrypt via **HTTP-01** challenge (no wildcard — No-IP
  free tier doesn't expose TXT records for DNS-01). Files at
  `/etc/letsencrypt/live/bb-psmdb.ddns.net/{fullchain,privkey}.pem`. Auto-renew
  via systemd timer; needs port 80 reachable for ~30 sec every 60 days.
- **TLS**: native in BB (via `tls.X509KeyPair.files` with `refresh_interval`)
  AND native in Envoy (via `DownstreamTlsContext`). Both support hot-reload
  on file change — `certbot --deploy-hook` rotation **without service restart**.
- **gRPC auth (Bazel clients)**: terminated **in Envoy** using the standard
  [`envoy.filters.http.jwt_authn`](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/jwt_authn_filter)
  filter. JWKS file shared with BB. Reason Envoy stays in the picture: it hosts
  our reapi-proxy that rewrites REAPI 2.3 → 2.0 for legacy MongoDB Bazel —
  this is non-negotiable. Adding JWT auth here is just extra YAML, no custom code.
- **HTTP auth (UI)**: native **OIDC** in BB with full code+refresh token flow,
  AES-GCM-encrypted session cookie, JMESPath claims-to-metadata.
- **GitHub teams gating**: GitHub OAuth alone is NOT enough (the OIDC user_info
  endpoint is single-URL; GitHub's `/user` does not return team membership).
  Solution: add **Dex** (1 small container) as IdP bridge — GitHub connector
  with `orgs[].teams[]` filter + `groups` claim in JWT.
- **No external reverse proxy beyond what we already have** (Envoy stays for
  reapi-proxy; we do NOT add caddy / nginx / oauth2-proxy).
- **No bb-autoscaler** — its algorithm (Prometheus + ASG) does not match our
  direct-gRPC + Hetzner Cloud setup. We keep our own `scaler.py`.

---

## 1. What BuildBarn provides natively (audit summary)

### 1.1 gRPC server — `AuthenticationPolicy.policy`

Source: [`bb-storage/pkg/proto/configuration/grpc/grpc.proto`](https://github.com/buildbarn/bb-storage/blob/master/pkg/proto/configuration/grpc/grpc.proto), `message AuthenticationPolicy`.

| Policy | Description | Status |
|---|---|---|
| `allow` | allow all (current default) | native |
| `deny` | deny all | native |
| `any` / `all` | OR/AND composition with metadata merge | native |
| **`jwt`** | `Authorization: Bearer <JWT>`, JWKS inline or file (300s reload), JMESPath claim validation + metadata extraction | native (HMAC, RSA, ECDSA, Ed25519) |
| **`tls_client_certificate`** | mTLS, X.509 CA verification + JMESPath SAN validation | native |
| `peer_credentials_jmespath_expression` | UNIX-socket SO_PEERCRED | native (in-pod use cases) |
| `remote` | forward auth to external gRPC AuthenticationServer | native |

`transport_security`:
- **`tls`** — server cert/key, `inline` OR `files.{certificate_path, private_key_path, refresh_interval}` (hot-reload).
- `alts` — Google ALTS (not applicable).

### 1.2 HTTP server — `AuthenticationPolicy.policy`

Source: [`bb-storage/pkg/proto/configuration/http/server/server.proto`](https://github.com/buildbarn/bb-storage/blob/master/pkg/proto/configuration/http/server/server.proto).

| Policy | Description | Status |
|---|---|---|
| `allow` / `deny` / `any` | same as gRPC | native |
| **`oidc`** | full OIDC code+refresh flow, AES-GCM cookie session, JMESPath claims→metadata | native (works with any RFC-compliant IdP: Dex, Keycloak, Auth0, Okta, …) |
| **`jwt`** | `Authorization: Bearer` for API access | native |
| `accept_header` | apply sub-policy only when `Accept` matches (e.g., OIDC only for browser requests) | native |
| `remote` | forward to external HTTP AuthenticationServer | native |

Verified by reading [`bb-storage/pkg/http/server/oidc_authenticator.go`](https://github.com/buildbarn/bb-storage/blob/master/pkg/http/server/oidc_authenticator.go):

- Uses `golang.org/x/oauth2` for token exchange + refresh.
- Encrypts session cookie with AES-GCM, key derived from full OIDC config + `cookie_seed` (any config change invalidates all sessions).
- Optional `use_id_token_claims` for IdPs that don't expose claims via UserInfo (some setups).
- Hot-reload of TLS via `refresh_interval` confirmed in `pkg/http/server/server.go`.

### 1.3 Both browser and scheduler use the same primitives

- `bb-browser/cmd/bb_browser/main.go:320` — calls `http_server.NewServersFromConfigurationAndServe(configuration.HttpServers, …)`.
- `bb-remote-execution/cmd/bb_scheduler/main.go:225` — calls the same for `AdminHttpServers`.

This means: **every HTTP policy (OIDC, JWT, TLS) works identically on the
browser, the scheduler admin UI, and the diagnostic HTTP servers** — only
the jsonnet config needs to change. No code changes anywhere.

Same is true for gRPC: frontend (`grpcServers`), scheduler
(`clientGrpcServers` / `workerGrpcServers` / `buildQueueStateGrpcServers`)
all share `bb-storage/pkg/grpc/server.go`.

### 1.4 What is NOT provided natively

| Want | Status | Workaround |
|---|---|---|
| HTTP Basic Auth | not native | not critical — JWT or OIDC are stronger; use `oauth2-proxy` only if mandated |
| ACME / Let's Encrypt auto-cert | not native | external certbot DNS-01 cron + `tls.files.refresh_interval` (hot-reload, no restart) |
| IP allowlist / firewall | not native | Hetzner Cloud Firewall (free, attached to VM) |
| HTTP rate limiting | not native | not critical for an internal cluster |
| GitHub team membership in OIDC claims | not directly | add Dex as IdP bridge (see §3) |

---

## 2. Why we need Dex (and not direct GitHub OAuth)

BB's OIDC implementation calls **one** `user_info_endpoint_url`. GitHub's
`/user` endpoint does NOT return team membership. Team membership is
exposed through `/user/teams` (a separate API, requires `read:org` scope).

Therefore, plain GitHub OAuth in BB gives only "user logged in" — there is no
way to enforce `percona*dev-psmdb` membership at the BB layer.

The standard solution is to put a thin OIDC IdP (Dex) in front of GitHub:

```
Browser → bb-browser / bb-scheduler-admin (OIDC clients)
           │
           ↓ (OIDC redirect)
        Dex IdP        ← GitHub connector with orgs[].teams[] filter
           │             (calls /user + /user/teams, merges into one JWT)
           ↓
   ID token with claim:
   groups: ["percona:build-engineers", "percona:iit", "percona:dev-psmdb"]
           │
           ↓
   bb-browser validates groups via JMESPath → grants/denies
```

[Dex GitHub connector docs](https://dexidp.io/docs/connectors/github/) — supports
exactly this use case; standard configuration, no custom code required.

Dex is one small container (~30 MB image), single jsonnet/yaml config,
state in SQLite (or Postgres if HA needed later). All auth logic lives in
config; we never write Go.

Allowed teams (mirrors [`IaC/psmdb.cd/init.groovy.d/matrix.groovy`](../psmdb.cd/init.groovy.d/matrix.groovy)):

- `percona*build-engineers`
- `percona*iit`
- `percona*dev-psmdb`

(Note: GitHub OIDC claim format from Dex is `org:team`, hence
`percona:build-engineers`. Jenkins matrix uses `org*team` only because of the
GitHub OAuth Jenkins plugin convention.)

---

## 3. Target architecture

All public services live on a **single hostname** (`bb-psmdb.ddns.net`),
distinguished by **port** rather than by sub-domain. This is forced by the
choice of free DDNS (No-IP free tier doesn't allow TXT records on DDNS
hostnames, so we cannot get a `*` wildcard via DNS-01; HTTP-01 is fine but
covers single names only). One cert, one hostname, four listening ports.

```
                          Internet (TCP only)
                                │
  ┌──────────┬────────┬─────────┼─────────┬──────────┬──────────┐
  ↓          ↓        ↓         ↓         ↓          ↓          ↓
 :22 SSH  :80 ACME  :5556 H   :7982 H   :7984 H   :8981 gRPCs  …
 (admin)  (HTTP-01) (Dex)     (sched.   (browser  (Envoy:                 
                              admin)    UI)       TLS+JWT)
                              │         │         │
                              │         │   ┌─────┴──────┐
                              │         │   │ JWT authn  │
                              │         │   │ (JWKS file)│
                              │         │   └─────┬──────┘
                              │         │         ↓
                              │         │   reapi-proxy:8990
                              │         │   (REAPI 2.3 → 2.0)
                              │         │         ↓
                              │         │   BB frontend:8980
                              │         │   (plaintext, docker net)
                              │         │
                              ▼         ▼
                            OIDC verify (groups in id_token)
                                   ↓
                  Dex on :5556 (issuer https://bb-psmdb.ddns.net:5556)
                                   ↓
                        GitHub OAuth + /user/teams
                                   ↓
            claims.groups = ["percona:dev-psmdb", …]

Internal (Hetzner private network 10.0.0.0/16):
    :8983 gRPC scheduler ↔ workers       (allow{} OK, network-isolated)
    :8984 gRPC BuildQueueState (scaler)  (allow{}, localhost-only)
```

Key point: Envoy is a **must-stay** component because reapi-proxy translates
REAPI v2.3 → v2.0 in `Capabilities.GetCapabilities` responses (legacy MongoDB
Bazel only understands v2.0). So Envoy is the natural place to terminate TLS
and validate the JWT — the BB frontend remains plaintext on the internal
docker network, listening only on the docker bridge.

### 3.1 Domain (interim) — `bb-psmdb.ddns.net` on No-IP free DDNS

Decided 2026-04-27: we use **`bb-psmdb.ddns.net`** (No-IP free tier) as the
**interim** hostname, with a single A record to the central VM
`95.216.189.238`:

```
$ dig @8.8.8.8 bb-psmdb.ddns.net
;; ANSWER SECTION:
bb-psmdb.ddns.net.   60   IN   A   95.216.189.238
```

Why this and not Hetzner DNS / `bb.psmdb.io`: `psmdb.io` is **not publicly
registered** (Hetzner DNS zone is authoritative only locally; `dig @8.8.8.8`
returns NXDOMAIN). Registering a real domain (~€10/year) is the right
long-term move; for an interim unblock we use a free DDNS that already
resolves on public DNS.

**Trade-offs of No-IP free vs. a registered domain or DuckDNS**:

- ❌ No TXT records on the DDNS hostname → no DNS-01 → no wildcard cert.
  Workaround: HTTP-01 with single-name cert, accept port-based service
  layout (current plan).
- ⚠️ Email-confirmation prompt every 30 days on No-IP free tier;
  forgetting frees the hostname. Operations runbook §6 has the calendar
  reminder + on-host weekly check.
- ✅ Already authenticated and working (no waiting on registrar/admins).
- ✅ Public DNS resolution (Let's Encrypt and GitHub OAuth happily resolve it).

**Cert acquisition** (already done):

```bash
certbot certonly --standalone --non-interactive --agree-tos \
  --email vorsel@gmail.com -d bb-psmdb.ddns.net
# → /etc/letsencrypt/live/bb-psmdb.ddns.net/{fullchain,privkey}.pem
# → expires 2026-07-26 (90d), systemd timer auto-renews
```

For the renewal Envoy/BB don't need to bounce — they all support
TLS hot-reload via either `refresh_interval` (BB) or SDS / signal reload
(Envoy). Detail in Step 1 below.

**Service layout**:

| URL | Purpose |
|---|---|
| `grpcs://bb-psmdb.ddns.net:8981` | Envoy → reapi-proxy → BB frontend (Bazel gRPC + JWT) |
| `https://bb-psmdb.ddns.net:5556` | Dex IdP (OIDC issuer) |
| `https://bb-psmdb.ddns.net:7984` | bb-browser UI (OIDC, group-gated) |
| `https://bb-psmdb.ddns.net:7982` | bb-scheduler admin UI (OIDC, group-gated) |
| `http://bb-psmdb.ddns.net:80` | reserved for ACME HTTP-01 challenge (renew only) |

**Migration plan when a real domain is approved** (e.g. `bb.psmdb.percona.com`):

1. Add new A record on Percona DNS, wait for propagation.
2. `certbot certonly --standalone -d bb.psmdb.percona.com` (or DNS-01 if
   we have TXT control on the new domain).
3. `sed -i 's|bb-psmdb.ddns.net|bb.psmdb.percona.com|g'` across configs.
4. Update GitHub OAuth App callback (one URL).
5. `docker compose up -d`. Old hostname keeps working until cert there expires.

Mechanical change set — no auth-flow rewrites.

---

## 4. Implementation steps

### Step 1 — TLS for Bazel-client gRPC endpoint **[DONE 2026-04-27]**

**Goal**: terminate TLS on the public gRPC port (`:8981` Envoy listener).
Browser/scheduler UIs (`:7984` / `:7982`) and Dex (`:5556`) stay plain
HTTP for now — TLS picked up by Step 2, auth picked up by Step 4 / Step 3 respectively.

What landed:

1. **Hetzner Floating IP `95.217.242.120`** assigned to the central VM,
   persistent via `/etc/network/interfaces.d/60-floating-ip.cfg`. Decouples
   public DNS from VM lifecycle: redeploying the VM keeps the IP and the
   cert intact.
2. **No-IP A-record** for `bb-psmdb.ddns.net` → `95.217.242.120` (was
   primary IP `95.216.189.238`).
3. **Let's Encrypt cert** via HTTP-01 (`certbot --standalone`):
   ```bash
   certbot certonly --standalone --non-interactive --agree-tos \
     --email vorsel@gmail.com -d bb-psmdb.ddns.net
   ```
   - Whole `letsencrypt` tree moved to the BB volume:
     `mv /etc/letsencrypt /var/lib/buildbarn/letsencrypt`,
     `ln -s /var/lib/buildbarn/letsencrypt /etc/letsencrypt`. Survives VM
     redeploy when the volume is reattached.
   - ECDSA P-256 key pair, expires `2026-07-26`. systemd timer
     `certbot.timer` auto-renews; HTTP-01 challenge needs port 80 open
     (no firewall yet, so it is reachable).
4. **Stable cert directory** `/var/lib/buildbarn/certs/`:
   - `fullchain.pem` and `privkey.pem` copied with symlinks resolved
     (`cp -L`), mode 0644 — readable inside containers regardless of any
     docker user-namespace remap. Original LE files keep their
     stricter perms.
   - Maintained by deploy-hook
     `/etc/letsencrypt/renewal-hooks/deploy/10-buildbarn.sh`: re-copies
     after each renewal and `docker compose restart envoy-proxy`.
5. **Envoy TLS** — `IaC/buildbarn/reapi-proxy/envoy.yaml` listener now has
   a `transport_socket` with `DownstreamTlsContext`,
   `alpn_protocols: [h2]`, cert/key files at
   `/etc/buildbarn/certs/{fullchain,privkey}.pem`. Frontend and reapi-proxy
   stay plaintext on the docker bridge (h2c) — no second hop, single TLS
   termination.
6. **docker-compose** — both
   `IaC/buildbarn/ondemand/compose/docker-compose.yml` (the actually-running
   stack) and `IaC/buildbarn/reapi-proxy/docker-compose.yml` (the standalone
   variant) mount `/var/lib/buildbarn/certs:/etc/buildbarn/certs:ro` into
   `envoy-proxy` and run with `user: "0:0"` (root inside container, fine
   because the container is isolated and never writes to the cert dir).

**Verified** with grpcurl + openssl from a developer Mac:

| Test | Expected | Result |
|---|---|---|
| `openssl s_client -connect …:8981 -alpn h2` | TLS 1.3, CN=bb-psmdb.ddns.net, issuer=Let's Encrypt, ALPN=h2 | ✅ |
| `grpcurl -d '{}' …:8981 …Capabilities/GetCapabilities` | REAPI v2 caps (low/highApiVersion 2.x) | ✅ |
| `grpcurl -plaintext …:8981 …` | timeout (TLS enforced) | ✅ (`context deadline exceeded`) |
| `grpcurl …:8981 list` (reflection over TLS) | Capabilities, CAS, Execution, ByteStream, Health, … | ✅ |

**`.bazelrc.psmdb` switch to `grpcs://`** is intentionally NOT included
in this jenkins-pipelines change — the Bazel client config lives in the
`percona-server-mongodb` repo where it's reviewed by a different team
(separate PSMDB ticket). Until that lands, MongoDB Bazel will still try
plain `grpc://` and fail; clients should temporarily call
`grpcs://bb-psmdb.ddns.net:8981` directly when smoke-testing.

**Future polish** (not blocking):
- Add Envoy SDS `watched_directory` so cert reloads without container
  restart (deploy-hook would only `chmod`/`cp`, not `restart`).
- Pre/post-hook to open port 80 only during renewal once a Hetzner
  firewall is added (Step deferred).

### Step 2 — TLS for bb-browser (:7984) and bb-scheduler admin UI (:7982) **[DONE 2026-04-28]**

**Goal**: stop serving the two public web UIs over plain HTTP. After
this step, every public endpoint on the central VM is TLS-only:

| Port | Service             | Termination | Cert source |
|------|---------------------|-------------|-------------|
| 8981 | Bazel gRPC (Envoy)  | Envoy       | `/var/lib/buildbarn/certs/` |
| 7984 | bb-browser HTTP UI  | bb-browser  | `/var/lib/buildbarn/certs/` |
| 7982 | bb-scheduler admin  | bb-scheduler| `/var/lib/buildbarn/certs/` |

We use BB's **native** TLS support (`tls.X509KeyPair.files` with
`refresh_interval`) instead of fronting bb-browser/bb-scheduler with a
second Envoy. Reasons:

* one less moving part (no extra container, no extra route);
* refresh_interval handles cert rotation in-process — same deploy-hook
  that already restarts Envoy just re-`cp`s the file and the BB
  process picks it up within `refresh_interval` (1 h);
* schema is identical to what we already use for Envoy on :8981, so
  the operational story stays consistent.

**Auth stays `allow{}` here** — OIDC via Dex is wired in Step 4.
This step is purely TLS so we can reason about transport security
independently from authentication.

#### What changed

1. New helper in
   [`compose/config/common.libsonnet`](./ondemand/compose/config/common.libsonnet) — `serverTls` returns the
   `{serverKeyPair: {files: {...}}}` block pointing at
   `/etc/buildbarn/certs/{fullchain,privkey}.pem` with
   `refreshInterval: '3600s'`. Both UIs reference the same helper so
   cert paths can't drift between the two services.

2. [`compose/config/browser.jsonnet`](./ondemand/compose/config/browser.jsonnet) — `httpServers[0].tls = common.serverTls`.

3. [`compose/config/scheduler.jsonnet`](./ondemand/compose/config/scheduler.jsonnet) — `adminHttpServers[0].tls =
   common.serverTls` only. `clientGrpcServers` (:8982 — docker bridge),
   `workerGrpcServers` (:8983 — Hetzner private network), and
   `buildQueueStateGrpcServers` (:8984 — localhost) explicitly stay
   plaintext: none of them is reachable from the public internet, so
   adding TLS would buy no security and only widen the cert-rotation
   surface.

4. [`compose/docker-compose.yml`](./ondemand/compose/docker-compose.yml) — both `browser` and `scheduler`
   services now mount `/var/lib/buildbarn/certs:/etc/buildbarn/certs:ro`,
   identical to the envoy-proxy mount. No `user: "0:0"` override needed
   because the cert files are mode 0644 and readable by any UID, including
   the `nobody` (UID 65534) that BB images run as by default.

5. [`scripts/create-central.sh`](./ondemand/scripts/create-central.sh) — three changes:
   a. New required env var **`PUBLIC_HOSTNAME`** (e.g.
      `bb-psmdb.ddns.net`). The script refuses to run without it; we
      explicitly do NOT default to `$PUBLIC_IP` because
      `https://<ip>:port` would never validate against the
      DNS-name-based Let's Encrypt cert and we'd silently produce
      broken UI links.
   b. The `__BB_PUBLIC_URL__` placeholder in `common.libsonnet` is
      now sed-replaced with `https://$PUBLIC_HOSTNAME:7984` (was
      `http://$PUBLIC_IP:7984`).
   c. `ondemand-pools.yaml`'s `scheduler_public_url` (which workers
      pick up as their `browserUrl`) follows the same scheme:
      `https://$PUBLIC_HOSTNAME:7982`.
   d. Smoke tests and the final summary banner now point at
      `https://$PUBLIC_HOSTNAME:{7982,7984}` and
      `grpcs://$PUBLIC_HOSTNAME:8981`.

#### Roll-out on a live central (no full re-deploy)

The repo changes can be applied in place; no need to re-run
`create-central.sh` end-to-end:

```bash
# 1. From operator laptop — sync the four touched files.
cd jenkins-pipelines/IaC/buildbarn/ondemand/compose
rsync -av config/ root@bb-psmdb.ddns.net:/var/lib/buildbarn/compose/config/
rsync -av docker-compose.yml root@bb-psmdb.ddns.net:/var/lib/buildbarn/compose/

# 2. On the central — re-bake the browserUrl placeholder (idempotent
#    if it was already replaced; the `sed` is a no-op then).
ssh root@bb-psmdb.ddns.net 'sed -i "s|__BB_PUBLIC_URL__|https://bb-psmdb.ddns.net:7984|g" \
    /var/lib/buildbarn/compose/config/common.libsonnet'

# 3. Restart only the two services we touched.
ssh root@bb-psmdb.ddns.net 'cd /var/lib/buildbarn/compose && \
    docker compose up -d browser scheduler'
```

#### Verification

```bash
# 1. TLS handshake + SAN match.
echo | openssl s_client -connect bb-psmdb.ddns.net:7984 -servername bb-psmdb.ddns.net 2>&1 | \
    grep -E 'subject=|issuer=|Verify return'
echo | openssl s_client -connect bb-psmdb.ddns.net:7982 -servername bb-psmdb.ddns.net 2>&1 | \
    grep -E 'subject=|issuer=|Verify return'
# Expect: subject=CN=bb-psmdb.ddns.net, issuer=Let's Encrypt E8, Verify return code: 0 (ok)

# 2. Plaintext must fail (TLS-only listener).
curl -v http://bb-psmdb.ddns.net:7984/ --max-time 3   # → connection-reset / EOF
curl -v http://bb-psmdb.ddns.net:7982/ --max-time 3   # → same

# 3. HTTPS must succeed.
curl -sI https://bb-psmdb.ddns.net:7984/ | head -1    # → HTTP/2 200
curl -sI https://bb-psmdb.ddns.net:7982/ | head -1    # → HTTP/2 200
```

**Future polish** (not blocking):
- Trim `refreshInterval` to e.g. 600s if we add cert rotation
  monitoring — 1 h is a comfortable default for a 90-day cert.
- Once a Percona-controlled domain replaces `bb-psmdb.ddns.net`,
  re-issue the cert and `sed` the new hostname in two places
  (`common.libsonnet` and `envoy.yaml`).

### Step 3 — Dex deployment

**Goal**: Dex becomes the OIDC IdP, gated by GitHub teams.
Rollback = remove Dex container; nothing else depends on it yet.

1. Register a **GitHub OAuth App** (personal first; swap to `percona` org-level later — see decision §7):
   - Homepage: `https://bb-psmdb.ddns.net:5556`
   - Callback: `https://bb-psmdb.ddns.net:5556/callback`
   - Scopes (auto): `read:user`, `user:email`, `read:org`
2. Add `dex` service to `docker-compose.yml` (image `ghcr.io/dexidp/dex:v2.41.0`
   or pinned), mount cert volume + `dex.yaml` config + sqlite volume,
   publish port `5556`.
3. `dex.yaml` skeleton:
   ```yaml
   issuer: https://bb-psmdb.ddns.net:5556
   storage: { type: sqlite3, config: { file: /var/dex/dex.db } }
   web:
     https: 0.0.0.0:5556
     tlsCert: /etc/buildbarn/certs/tls.crt
     tlsKey:  /etc/buildbarn/certs/tls.key
   connectors:
   - type: github
     id: github
     name: GitHub
     config:
       clientID:     $GITHUB_OAUTH_CLIENT_ID
       clientSecret: $GITHUB_OAUTH_CLIENT_SECRET
       redirectURI:  https://bb-psmdb.ddns.net:5556/callback
       orgs:
       - name: percona
         teams: [build-engineers, iit, dev-psmdb]
       loadAllGroups: false
       teamNameField: slug
   oauth2:
     skipApprovalScreen: true
   staticClients:
   - id: bb-browser
     name: 'Buildbarn Browser'
     secret: $BB_BROWSER_OIDC_SECRET
     redirectURIs: [https://bb-psmdb.ddns.net:7984/oidc-callback]
   - id: bb-scheduler-admin
     name: 'Buildbarn Scheduler Admin'
     secret: $BB_SCHED_OIDC_SECRET
     redirectURIs: [https://bb-psmdb.ddns.net:7982/oidc-callback]
   ```
4. Smoke-test: open `https://bb-psmdb.ddns.net:5556/.well-known/openid-configuration`,
   click through GitHub login from a browser.

### Step 4 — Wire OIDC into bb-browser and scheduler admin

**Goal**: UI now requires GitHub login + team membership.

`browser.jsonnet` and `scheduler.jsonnet` `adminHttpServers` get:

```jsonnet
local certPath = '/etc/buildbarn/certs/tls.crt';
local keyPath  = '/etc/buildbarn/certs/tls.key';
local serverTls = {
  serverKeyPair: {
    files: { certificatePath: certPath, privateKeyPath: keyPath, refreshInterval: '3600s' },
  },
};

local groupsAllowExpression = |||
  contains(authenticationMetadata.public.groups, 'percona:build-engineers') ||
  contains(authenticationMetadata.public.groups, 'percona:iit') ||
  contains(authenticationMetadata.public.groups, 'percona:dev-psmdb')
|||;

local oidcPolicy(clientId, secretEnv, redirectUrl, cookieSeedEnv) = {
  oidc: {
    clientId: clientId,
    clientSecret: std.extVar(secretEnv),
    authorizationEndpointUrl: 'https://bb-psmdb.ddns.net:5556/auth',
    tokenEndpointUrl:         'https://bb-psmdb.ddns.net:5556/token',
    userInfoEndpointUrl:      'https://bb-psmdb.ddns.net:5556/userinfo',
    scopes: ['openid', 'email', 'groups', 'offline_access'],
    redirectUrl: redirectUrl,
    cookieSeed: std.extVar(cookieSeedEnv),
    metadataExtractionJmespathExpression: {
      expression: '{ "public": { "email": email, "groups": groups, "login": preferred_username } }',
    },
  },
};

// In browser.jsonnet:
httpServers: [{
  listenAddresses: [':7984'],
  tls: serverTls,
  authenticationPolicy: oidcPolicy(
    'bb-browser', 'BB_BROWSER_OIDC_SECRET',
    'https://bb-psmdb.ddns.net:7984/oidc-callback',
    'BB_BROWSER_COOKIE_SEED',
  ),
}],
authorizer: { jmespathExpression: { expression: groupsAllowExpression } },

// In scheduler.jsonnet:
adminHttpServers: [{
  listenAddresses: [':7982'],
  tls: serverTls,
  authenticationPolicy: oidcPolicy(
    'bb-scheduler-admin', 'BB_SCHED_OIDC_SECRET',
    'https://bb-psmdb.ddns.net:7982/oidc-callback',
    'BB_SCHED_COOKIE_SEED',
  ),
}],
modifyDrainsAuthorizer:   { jmespathExpression: { expression: groupsAllowExpression } },
killOperationsAuthorizer: { jmespathExpression: { expression: groupsAllowExpression } },
```

`cookieSeed` = 32 random bytes, base64-encoded; stored in env file
(read by `docker-compose` and surfaced via `--ext-str` to `jsonnet`).

### Step 5 — JWT for Bazel clients (RS256), enforced in Envoy

**Goal**: every Bazel client must present a valid signed JWT. Validation
happens in Envoy (since Envoy is already on the path for reapi-proxy);
the BB frontend itself stays `allow{}` because all traffic to it has
already been authenticated upstream.

1. Generate one RSA-2048 key pair (one-time, outside repo):
   ```bash
   openssl genrsa -out /secrets/rbe-jwt-private.pem 2048
   openssl rsa  -in /secrets/rbe-jwt-private.pem -pubout -out /secrets/rbe-jwt-public.pem
   step crypto key format --jwk /secrets/rbe-jwt-public.pem > bazel-clients-jwks.json
   ```
   Add `kid` (key ID) to JWKS, e.g. `"kid": "rbe-2026-01"`. Rotate annually
   by issuing new keys with new `kid` and updating JWKS file.
2. Mount `bazel-clients-jwks.json` (public-only, safe to ship in image) into
   the Envoy container at `/etc/envoy/jwks/bazel-clients.json`.
3. Add the JWT filter to Envoy `http_filters`, **before** the router:
   ```yaml
   http_filters:
   - name: envoy.filters.http.jwt_authn
     typed_config:
       "@type": type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.JwtAuthentication
       providers:
         percona_rbe_issuer:
           issuer: percona-rbe-issuer
           audiences: [percona-rbe]
           local_jwks:
             filename: /etc/envoy/jwks/bazel-clients.json
           forward: true                # forward token downstream for traceability
           forward_payload_header: x-jwt-payload  # optional, useful for logging
           from_headers:
           - name: authorization
             value_prefix: "Bearer "
       rules:
       - match: { prefix: "/" }
         requires:
           provider_name: percona_rbe_issuer
   - name: envoy.filters.http.router
     typed_config:
       "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
   ```
   Refs: [Envoy `jwt_authn` filter docs](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/jwt_authn_filter),
   [`JwtAuthentication` proto](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/jwt_authn/v3/config.proto).
   - JWKS file is reloaded automatically when `local_jwks.filename` changes
     and Envoy is reloaded; for fully hot-reload use SDS (later improvement).
4. Token issuance utility `scripts/issue-rbe-jwt.sh <subject> [validity-days]`:
   - signs `{sub, iss: percona-rbe-issuer, aud: percona-rbe, iat, exp, kid}` with private key.
   - Default validity 365 days.
   - Output: a single base64url string. To revoke: rotate JWKS `kid`.
5. Install:
   - **Jenkins**: store as Jenkins credential `rbe-jwt-token` (Secret text).
     `withCredentials([string(credentialsId:'rbe-jwt-token', variable:'RBE_JWT_TOKEN')])`
     in pipelines.
   - **Devs**: distribute individually (1 token per person), they `export RBE_JWT_TOKEN=...` in shell init.

**BB-side note**: with Envoy enforcing the JWT, BB scheduler `clientGrpcServers`
and frontend `grpcServers` can stay `allow{}` — Envoy is the only ingress
to them. We can OPTIONALLY also enable BB JWT auth as defense-in-depth
(Envoy does it primarily; BB does it secondarily). Adds CPU cost but no
functional benefit. Default: keep BB `allow{}`, document that all auth lives
in Envoy.

### Step 6 — Bazel client side (`.bazelrc.psmdb` + `wrapper_hook.py`)

In every PSMDB branch ([`v8.0`](../../percona-server-mongodb/.bazelrc.psmdb), `v8.3`, `master`):

```
build:psmdb_buildfarm --remote_executor=grpcs://bb-psmdb.ddns.net:8981
build:psmdb_buildfarm --remote_cache=grpcs://bb-psmdb.ddns.net:8981
# JWT injected by wrapper_hook from RBE_JWT_TOKEN env
```

`wrapper_hook.py` (already present in PSMDB) gets a small extension: when
`RBE_JWT_TOKEN` is set, append `--remote_header=authorization=Bearer ${RBE_JWT_TOKEN}`
to the command line. Avoids leaking the token into committed files.

### Step 7 — Hetzner Cloud Firewall

Create one firewall (`rbe-central-fw`) attached to the central VM:

| Port | Proto | Source | Purpose |
|---|---|---|---|
| 80   | TCP | 0.0.0.0/0 | ACME HTTP-01 renewal (Let's Encrypt) |
| 5556 | TCP | 0.0.0.0/0 | Dex OIDC IdP |
| 7982 | TCP | 0.0.0.0/0 | bb-scheduler admin UI |
| 7984 | TCP | 0.0.0.0/0 | bb-browser UI |
| 8981 | TCP | 0.0.0.0/0 | Envoy → BB frontend gRPC (TLS+JWT) |
| 22   | TCP | Percona VPN/office CIDRs | SSH |
| (other) | — | DROP | default deny |

Internal:
- Worker VMs see scheduler `:8983` over Hetzner private network only;
  worker firewall blocks all public inbound except SSH from admin.
- `:8984` BuildQueueState bound to `127.0.0.1`, used by `scaler.py` only.

---

## 5. Files to create / modify

In `jenkins-pipelines/IaC/buildbarn/ondemand/compose/`:

| File | Change |
|---|---|
| `docker-compose.yml` | + `dex` service; KEEP `reapi-proxy` + `envoy` (REAPI 2.3→2.0 compat); mounts for `/etc/buildbarn/certs`, `/etc/buildbarn/jwt`, `/etc/buildbarn/dex` |
| `IaC/buildbarn/reapi-proxy/envoy.yaml` | + listener `transport_socket` (TLS); + `envoy.filters.http.jwt_authn` filter; + JWKS volume mount |
| `config/scheduler.jsonnet` | + TLS + OIDC (adminHttp) + group authorizers; clientGrpcServers stay `allow{}` (Envoy already enforced JWT) |
| `config/browser.jsonnet` | + TLS + OIDC + group authorizer |
| `config/frontend.jsonnet` | unchanged — stays plaintext on internal docker network behind Envoy |
| `config/dex.yaml` (new) | full Dex config |
| `config/bazel-clients-jwks.json` (new) | public JWKS, mounted into Envoy |

In `jenkins-pipelines/IaC/buildbarn/ondemand/scripts/`:

| File | Purpose |
|---|---|
| `init-tls.sh` (new) | first-time cert acquisition (DNS-01) |
| `issue-rbe-jwt.sh` (new) | mint JWT tokens for users / Jenkins |
| `init-jwt.sh` (new) | one-time RSA key pair + JWKS generation |
| `create-central.sh` (existing) | extend: install certbot cron, attach Hetzner Firewall, mount cert/JWT/Dex volumes |
| `secrets.env.example` (new) | template for env file with all OIDC secrets, cookie seeds, GitHub creds |

In `percona-server-mongodb/`:

| File | Change |
|---|---|
| `.bazelrc.psmdb` | switch endpoints to `grpcs://`; remove plain `grpc://` |
| `bazel/wrapper_hook/wrapper_hook.py` | inject `--remote_header` from `$RBE_JWT_TOKEN` |

In docs:

| File | Change |
|---|---|
| `IaC/buildbarn/ondemand/README.md` | Authentication & TLS section |
| `IaC/buildbarn/buildbarn-auth-tls-plan.md` (this) | progress tracking |

---

## 6. Operations runbook (preview)

- **Add a developer**: `./issue-rbe-jwt.sh user@percona.com 365` → send token via secure channel; user adds GitHub team membership in `percona*dev-psmdb`.
- **Revoke a JWT key**: edit JWKS file, rotate `kid`, re-issue tokens. JWKS reload is automatic (300s).
- **Revoke a UI session**: change `cookieSeed` in env → rolling restart of bb-browser + scheduler-admin → all sessions invalidated; users re-login.
- **Off-board user**: remove from `percona*dev-psmdb`/etc on GitHub; their next OIDC login (or refresh) is denied at Dex layer.
- **Cert renewal**: certbot's systemd timer + `--deploy-hook` symlinks new cert into `/etc/buildbarn/certs/` → BB hot-reloads, Envoy reloaded via signal, Dex restarted.
- **Cert emergency rotation**: replace files in `/etc/buildbarn/certs/` in place; BB picks up within `refresh_interval` (default 1h, can lower to 60s); restart Envoy + Dex.
- **No-IP hostname keepalive (free tier)**: every 30 days No-IP emails the
  account owner (vorsel@gmail.com) asking to confirm the hostname is still
  in use; if missed, `bb-psmdb.ddns.net` is freed and someone else can
  register it. **Calendar reminder set for the 28th of every month**.
  An on-host weekly check (`scripts/check-noip.sh` — TODO) will alert if
  the hostname stops resolving to our IP.

---

## 7. Decisions log & remaining open questions

### Resolved

| # | Decision | Rationale |
|---|---|---|
| 1 | **Interim domain: `bb-psmdb.ddns.net`** (No-IP free DDNS). Single host, port-based service layout. | `psmdb.io` we initially planned was never publicly registered (NXDOMAIN on public resolvers); registering a real domain is the right next step but takes admin approval. No-IP is free, public-resolvable, A record was set up in 5 min. Trade-off: no DNS-01 → no wildcard cert → port-based instead of subdomain-based service split. |
| 2 | **Cert acquisition: Let's Encrypt via HTTP-01** (`certbot --standalone`) on port 80 of the central VM. systemd timer auto-renews. | DNS-01 not possible because No-IP free tier doesn't expose TXT record control. HTTP-01 with single-name cert is simple, reliable, and covers all four ports of the same host. |
| 3 | **Hetzner Floating IP `95.217.242.120`** attached to the central VM, persistent via `/etc/network/interfaces.d/60-floating-ip.cfg`. DNS A-record points at the FI, not at the VM's primary IP. | Decouples the public-facing IP from VM lifecycle. Recreating the central VM no longer churns DNS / cert / OAuth callback URLs — just `hcloud floating-ip assign` after `create-central.sh`. Cost: €1/month per IP. |
| 4 | **Cert lives on the BB volume**: `/var/lib/buildbarn/letsencrypt/` (whole letsencrypt tree moved + symlinked from `/etc/letsencrypt`); deploy-hook copies resolved files to `/var/lib/buildbarn/certs/` with mode 0644 for container consumption. | Persists across VM redeploys. The 0644 copy avoids docker user-namespace traversal issues we hit when mounting the LE tree directly into a non-root container. Renewal: certbot.timer → deploy-hook re-copies → restarts envoy-proxy. |
| 5 | **TLS terminated only in Envoy** for now. Frontend / reapi-proxy / scheduler-grpc / worker-grpc stay plaintext on the docker bridge or the Hetzner private network. | Single termination point = single cert mount + single restart on renewal. BB and Dex TLS land in Steps 2-3 when their config files are touched anyway. |
| 6 | **GitHub OAuth App: personal app first**, `clientID` + `clientSecret` stored in `secrets.env`. Will swap to a Percona org-level OAuth App after Percona admins approve a request. The swap is mechanical — only `clientID` / `clientSecret` env vars change in `dex.yaml` (Dex re-reads on restart). | Personal app is created in 1 minute; org-level has indefinite admin-approval lead time. Acceptable risk: only people we hand individual JWTs / login URLs to can authorize against the personal app, and Dex still gates on `orgs[].teams[]`. |

### Personal → org-level OAuth App swap (later)

When Percona admins approve a Percona-org GitHub OAuth App, the migration is:

1. Register the new OAuth App under the `percona` org with the same homepage / callback URLs.
2. Replace `GITHUB_OAUTH_CLIENT_ID` / `GITHUB_OAUTH_CLIENT_SECRET` in `secrets.env`.
3. `docker compose restart dex`.
4. Existing user sessions remain valid until their refresh token expires; on next refresh they get redirected through the new app and re-consent silently (as long as the GitHub user is in one of the allowed teams).
5. Delete the personal app on GitHub.

The Dex `connectors[].config.orgs[].teams[]` allow-list does not change — team gating is independent of which OAuth App is used.

### Decisions confirmed (2026-04-28)

| # | Decision | Rationale |
|---|---|---|
| 4 | **Rollout = (c) in-place rolling** | Step 1 (TLS gRPC) → smoke → Step 2 (TLS UI) → smoke → Step 3 (Dex stand-alone, not yet wired) → smoke → Step 4 (UI OIDC) → smoke → Step 5 (JWT for Bazel) → smoke. Rollback at any step is `git revert` + `docker compose up -d`. |
| 5 | **Dex storage = SQLite on persistent volume** (`/var/lib/buildbarn/dex/dex.db`, mode 0600) | Dex's storage holds OAuth auth-codes, refresh tokens, offline sessions, and Dex's own JWT signing-key history (rotates every 6 h, keeps 24 h). Users come from GitHub; Dex itself doesn't store user accounts. SQLite cost: one tiny file on the same volume that already holds CAS+certs. Survives container restart and central VM redeploy (volume persists). Postgres would be overkill for ~10 interactive UI users; `memory:` would force a re-login on every Dex restart. Migration path: switch the `storage:` block to `postgres`/`mysql` later if scale demands — no data needs to be migrated, since Dex storage is all short-lived state. |

### Pending — please confirm before Step 5 (Bazel JWT)

| # | Question | Default if not specified |
|---|---|---|
| 6 | **JWT lifetime / rotation cadence** — 1y default? Or shorter (90d) with auto-rotate? | 1y default for human users, `kid` rotation annually. Jenkins token: same 1y + Jenkins-credentials manual rotation. Shorter terms only if infosec asks. |

---

## 8. What we deliberately do NOT do

- **No additional Caddy / nginx / oauth2-proxy.** We already have Envoy in
  the path (for reapi-proxy REAPI v2.3 → v2.0 compat); adding TLS + JWT to
  Envoy is just YAML — no second proxy layer.
- **No "drop Envoy" simplification.** It was tempting, but Envoy is the
  reason MongoDB's Bazel works at all (their bundled Bazel only speaks REAPI
  v2.0; bb-storage advertises v2.3). reapi-proxy lives behind Envoy and
  rewrites Capabilities responses; removing Envoy would break every PSMDB
  build.
- **No bb-autoscaler.** Algorithm is Prometheus + AWS ASG / k8s; we have neither. Our `scaler.py` reads `BuildQueueState` gRPC directly and drives Hetzner Cloud API. We may borrow the *idea* of `quantile_over_time(0.95, …, [4h:])` for queue smoothing, but as in-process logic, not as a new service.
- **No custom Go middleware.** Everything achievable via jsonnet config + JMESPath expressions.
- **No worker-side authentication on `:8983`.** Workers live on Hetzner private network with the central VM; firewall blocks public access. Adding mTLS here is a possible future hardening, but not justified now.

---

## 9. References

- [BuildBarn org](https://github.com/buildbarn) (15 repos, cloned to `~/percona/repos/buildbarnrepos/`).
- [`bb-storage/pkg/proto/configuration/grpc/grpc.proto`](https://github.com/buildbarn/bb-storage/blob/master/pkg/proto/configuration/grpc/grpc.proto) — gRPC `AuthenticationPolicy`, `transport_security`.
- [`bb-storage/pkg/proto/configuration/http/server/server.proto`](https://github.com/buildbarn/bb-storage/blob/master/pkg/proto/configuration/http/server/server.proto) — HTTP auth incl. OIDC.
- [`bb-storage/pkg/proto/configuration/jwt/jwt.proto`](https://github.com/buildbarn/bb-storage/blob/master/pkg/proto/configuration/jwt/jwt.proto) — JWT JWKS + claim validation.
- [`bb-storage/pkg/proto/configuration/tls/tls.proto`](https://github.com/buildbarn/bb-storage/blob/master/pkg/proto/configuration/tls/tls.proto) — TLS X.509 key-pair config.
- [`bb-storage/pkg/proto/configuration/auth/auth.proto`](https://github.com/buildbarn/bb-storage/blob/master/pkg/proto/configuration/auth/auth.proto) — `AuthorizerConfiguration`.
- [`bb-storage/pkg/http/server/oidc_authenticator.go`](https://github.com/buildbarn/bb-storage/blob/master/pkg/http/server/oidc_authenticator.go) — OIDC implementation.
- [Dex IdP](https://dexidp.io/) and [GitHub connector](https://dexidp.io/docs/connectors/github/).
- [`IaC/psmdb.cd/init.groovy.d/matrix.groovy`](../psmdb.cd/init.groovy.d/matrix.groovy) — current Jenkins authorization matrix (source of allowed groups).
