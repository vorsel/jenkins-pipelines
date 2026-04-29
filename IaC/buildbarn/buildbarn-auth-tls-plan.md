# BuildBarn RBE — Authentication & TLS Plan

> Status: **COMPLETE for the application-layer auth/TLS surface.**
> Steps 1-5d all DONE and E2E-verified across `master` / `v8.3` / `v8.0`
> PSMDB branches (PSMDB-2034 / PSMDB-2040 / PSMDB-2043). The pipeline
> on a fresh laptop is: `rbe_login.py` → device-code OAuth via Dex →
> `wrapper_hook.py` injects the JWT → Bazel build over
> `grpcs://bb-psmdb.ddns.net:8981` (Envoy TLS + `jwt_authn`) → workers
> fetch CAS/AC over the private `frontend:8980` hop. Verified end-to-end:
> master 18 209-action build 6:23 wall (10 437 cache hits + 2 remote);
> v8.0 12 932-action build 17:06 wall (1 995 cache hits + 4 314 remote).
> Step 6 (Hetzner Cloud Firewall) intentionally **DEFERRED** — see
> §"Step 6 — Hetzner Cloud Firewall — DEFERRED" for the trigger
> conditions (upstream merge, production URI, possible Floating-IP
> migration). Build observability (history of past invocations,
> per-action timeline) is tracked separately in
> [`buildbarn-portal-plan.md`](./buildbarn-portal-plan.md) — out of
> scope for this plan, since it's an observability concern, not an
> auth concern.
> Last update: 2026-04-29.
> Tracking: PSMDB-2040 (jenkins-pipelines side); separate PSMDB ticket for
> the `percona-server-mongodb` `.bazelrc.psmdb` / `wrapper_hook.py` switch.
> Working domain: **`bb-psmdb.ddns.net`** (No-IP free DDNS, dev cluster).
> Public IP: a Hetzner Floating IP (attached to the central VM,
> survives VM redeploy). The exact value is in the operator's
> `INFRASTRUCTURE.md` runbook (template:
> `IaC/buildbarn/INFRASTRUCTURE.md.example`) — kept out of git on
> purpose; see `.gitignore`.
> TLS cert: Let's Encrypt via HTTP-01 standalone, ECDSA P-256, expires 2026-07-26.
> Cert path inside containers: `/etc/buildbarn/certs/{fullchain,privkey}.pem`
> (deploy-hook copies from `/etc/letsencrypt/live/.../` to
> `/var/lib/buildbarn/certs/`; mode 0644).
> Related docs: [`buildbarn-remote-execution-setup.md`](./buildbarn-remote-execution-setup.md), [`buildbarn-ondemand-scaler.md`](./buildbarn-ondemand-scaler.md), [`ondemand/README.md`](./ondemand/README.md), [`buildbarn-portal-plan.md`](./buildbarn-portal-plan.md) (proposed follow-up: build observability via bb-portal).

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
  filter. JWTs are **issued by Dex** via the OAuth 2.0 Device Authorization
  Grant (RFC 8628) — same identity model as the UIs (GitHub team allow-list),
  no parallel "RBE-only" key universe, no manual key rotation, auto-refresh
  on the client side. Envoy fetches `https://bb-psmdb.ddns.net:5556/keys`
  via `remote_jwks` (cache 600s). Reason Envoy stays in the picture: it
  hosts our reapi-proxy that rewrites REAPI 2.3 → 2.0 for legacy MongoDB
  Bazel — this is non-negotiable. Adding JWT auth here is just extra YAML,
  no custom code.
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

Internal (Hetzner private cloud network — see `${HCLOUD_NETWORK_CIDR}`):
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
**interim** hostname, with a single A record pointing at the central
VM's Hetzner Floating IP (the live value lives in `INFRASTRUCTURE.md`).
You can verify resolution from any public network with
`dig @8.8.8.8 bb-psmdb.ddns.net` — the answer should match
`${PUBLIC_IP}` from your `.env`.

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
  --email "${LE_EMAIL}" -d "${PUBLIC_HOSTNAME}"
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

1. **Hetzner Floating IP** assigned to the central VM, persistent via
   `/etc/network/interfaces.d/60-floating-ip.cfg`. Decouples public DNS
   from VM lifecycle: redeploying the VM keeps the IP and the cert
   intact. (Live IP recorded in `INFRASTRUCTURE.md` — kept out of git;
   pull from `${PUBLIC_IP}` in your `.env`.)
2. **No-IP A-record** for `bb-psmdb.ddns.net` → `${PUBLIC_IP}` (was
   pointing at the VM's primary IP, which rotates on redeploy).
3. **Let's Encrypt cert** via HTTP-01 (`certbot --standalone`):
   ```bash
   certbot certonly --standalone --non-interactive --agree-tos \
     --email "${LE_EMAIL}" -d "${PUBLIC_HOSTNAME}"
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

### Step 3 — Dex deployment ✅ DONE (2026-04-28)

**Goal**: Dex becomes the OIDC IdP, gated by GitHub teams.
Rollback = remove Dex container; nothing else depends on it yet
(Step 4 is what plugs bb-browser / bb-scheduler into it).

#### Implementation

1. **GitHub OAuth App** registered (operator's personal account for now,
   to be swapped for an org-level App once admin approval lands —
   see decision §7).
   - Homepage:   `https://bb-psmdb.ddns.net:5556`
   - Callback:   `https://bb-psmdb.ddns.net:5556/callback`
   - Scopes (auto-granted on first login): `read:user`, `user:email`, `read:org`.
   - "Enable Device Flow" — left **off** (we're a confidential client,
     not a CLI / TV app).
   - `GITHUB_OAUTH_CLIENT_ID` and `GITHUB_OAUTH_CLIENT_SECRET` exported
     in the operator's `~/.bashrc`. Re-runs of `create-central.sh` pick
     them up automatically.

2. **`compose/dex/dex.yaml`** (new file, committed). Highlights — see
   the file's own header for the per-block rationale:
   - `issuer: https://bb-psmdb.ddns.net:5556` (must match SAN; baked
     into every `iss` claim).
   - `storage.type: sqlite3` at `/var/dex/dex.db` (decision §5).
   - `web.https` listener with the same Let's Encrypt cert that
     envoy-proxy / browser / scheduler use (`/etc/buildbarn/certs/`).
   - GitHub connector pointing at `orgs[].teams[]`:
     `[build-engineers, iit, dev-psmdb]` (slugs, not display names —
     see §6).
   - `expiry.idTokens: 1h`, `refreshTokens.absoluteLifetime: 8760h` (1 y),
     `validIfNotUsedFor: 2160h` (90 d) — matches operator-facing
     decisions in §5 of the decisions table.
   - Two `staticClients` pre-declared: `bb-browser` and
     `bb-scheduler-admin`, each with a per-service secret loaded from
     env at startup.

3. **`compose/docker-compose.yml`** — new `dex` service (Alpine-based
   image `ghcr.io/dexidp/dex:${DEX_IMAGE_TAG}`, runs as `1001:1001`).
   Mounts `dex.yaml` read-only, the cert dir read-only, and the
   persistent dex DB dir read-write. Healthcheck = `wget /healthz`.

4. **`scripts/create-central.sh`**:
   - Preflight rejects deploy if `GITHUB_OAUTH_CLIENT_ID` or
     `GITHUB_OAUTH_CLIENT_SECRET` aren't exported, plus a sanity
     pattern check on the client ID shape.
   - State-dir bootstrap creates `/var/lib/buildbarn/dex` chowned
     `1001:1001` mode `0700` (Dex's user, no one else).
   - `bake_env` writes the GitHub creds into `.env` (mode 0600) and
     **generates** `BB_BROWSER_OIDC_SECRET` + `BB_SCHED_OIDC_SECRET`
     once with `openssl rand -hex 32`, then preserves them on every
     re-run (rotating them silently would invalidate every active
     operator session).
   - Smoke test fetches `/.well-known/openid-configuration` and
     asserts `.issuer` matches the public hostname; mismatch = stale
     `dex.yaml` not yet picked up by a `docker compose restart dex`.
   - Summary block prints the discovery URL.

5. **GitHub team slug verification** (one-off, off-band):
   ```bash
   GH_TOKEN=ghp_… curl -fsS \
     -H "Authorization: Bearer $GH_TOKEN" \
     -H "Accept: application/vnd.github+json" \
     https://api.github.com/orgs/percona/teams \
     | jq -r '.[] | "\(.slug)\t\(.name)"' | grep -Ei 'build|iit|psmdb'
   ```
   Token requires `read:org`. The slug column is what goes in
   `dex.yaml > orgs[].teams[]` — display names will be silently
   ignored by Dex's GitHub connector and produce a "user not in
   any required org/team" rejection at login.

#### Verification

- [x] `curl https://bb-psmdb.ddns.net:5556/.well-known/openid-configuration | jq .issuer`
      returns `"https://bb-psmdb.ddns.net:5556"`.
- [x] `docker compose ps dex` shows `healthy`.
- [x] No-team-membership account → GitHub login → Dex callback shows
      "User <login> is not in any of the required organizations or teams".
      (Verified in Step 4 once UI is wired; for Step 3 the static
      clients are declared but not yet consumed.)

### Step 4 — Wire OIDC into bb-browser and scheduler admin ✅ DONE (2026-04-28)

**Goal**: UIs now delegate login to Dex+GitHub, gated to the three
allowed teams. End-to-end flow: anonymous request → 302 to
`https://bb-psmdb.ddns.net:5556/auth` → GitHub OAuth consent →
Dex `/callback` enforces `orgs[].teams[]` membership → 302 to
`https://bb-psmdb.ddns.net:{7984|7982}/oidc-callback` → BB drops an
AES-GCM-encrypted session cookie keyed off `cookieSeed`.

#### Architecture choices that diverged from the original sketch

1. **Authorization gating lives in Dex, not in BB.** BB's HTTP server
   proto (`bb-storage/pkg/proto/configuration/http/server/server.proto::
   Configuration`) has only `authentication_policy`, NO authorizer
   field. There's no place to plug a `jmespathExpression` authorizer
   on `httpServers` like the earlier sketch implied. Dex's GitHub
   connector already enforces `orgs[].teams[]` at `/callback` (returns
   "User not in any of the required organizations or teams" for
   non-members), so any user who reaches BB's `/oidc-callback` with a
   valid auth code is, by construction, in `[build-engineers, iit,
   dev-psmdb]`. We don't need a second JMESPath gate.

2. **`useIdTokenClaims: {}` instead of `userInfoEndpointUrl`.** BB's
   `IDTokenOIDCClaimsFetcher` (oidc_authenticator.go:328-356)
   base64-decodes the id_token payload directly without verifying its
   signature; trust comes from the TLS-secured `/token` round-trip.
   This saves a `/userinfo` round-trip and avoids Dex's connector-
   specific `/userinfo` shape — `groups` only appears in id_token by
   default in the GitHub connector path.

3. **Internal docker network alias for `bb-psmdb.ddns.net`.** The OIDC
   config uses the same public hostname for BOTH the user-browser-
   facing `/auth` redirect AND the BB-internal `/token` exchange.
   Without help, the BB → /token call would have to NAT-loop through
   the host's external interface. Adding `aliases: [bb-psmdb.ddns.net]`
   to the dex service in docker-compose.yml means BB resolves the
   hostname via docker's embedded DNS to the dex container directly;
   the call stays on the docker bridge, and TLS validation still
   succeeds because the cert SAN is matched against the URL hostname,
   not the destination IP.

4. **Restart-list expanded to all `./config/`-mounted services.** First
   deploy of this step left `bb-browser` running with the prior
   `allow{}` policy for ~5h while smoke tests reported `302` for
   scheduler and `200` for browser — exactly because `compose_up` only
   restarted `scheduler scaler` (it was sized for the predeclared-queue
   rollout and we never revisited it). `docker compose up -d` only
   recreates a service when its compose definition (image, env,
   volumes) changes, NOT when the bind-mounted file content changes.
   Fix in `scripts/create-central.sh` is to `restart` every service
   that mounts `./config/` (browser, frontend, scheduler, storage-{0,1},
   plus scaler whose own dir is rsynced from `./scaler/`, plus `dex`
   whose dex.yaml is also bind-mounted). Cost: a ~10s rolling bounce
   on every redeploy. Cheap insurance against the class of bug "we
   silently shipped stale config".

5. **Dex `staticClients` doesn't expand `$VAR`.** First end-to-end
   login attempt failed at the BB → Dex `/token` exchange with
   `oauth2: "invalid_client" "Invalid client credentials."`. Cause:
   we wrote `secret: $BB_SCHED_OIDC_SECRET` in `dex.yaml`. Dex's
   environment-variable expansion (`os.ExpandEnv`, gated by
   `DEX_EXPAND_ENV` defaulting to `true`) ONLY runs on
   `connectors[].config.*` and `storage.config.*` — see
   `cmd/dex/config.go::Connector.UnmarshalJSON`. The top-level
   `staticClients[].secret` field stores its value verbatim, so Dex
   was comparing the BB-supplied real hex against the literal string
   `"$BB_SCHED_OIDC_SECRET"`. The dedicated escape hatch is the
   `secretEnv: VAR_NAME` (no `$`) field on `storage.Client` —
   resolved via `os.Getenv()` at config load time, distinct from the
   raw-text `os.ExpandEnv` path. Same caveat for `idEnv`. Fix:
   replaced both `secret: $...` lines with `secretEnv: ...` in
   `dex.yaml` (`bb-browser`, `bb-scheduler-admin`); the connector's
   `clientID/clientSecret` lines stay on `$VAR` syntax because
   they're inside `connectors[].config.*` where expansion does run.

#### Implementation

1. **`compose/config/common.libsonnet`** — added a generic
   `oidcAuth(clientId, clientSecret, redirectUrl, cookieSeed)` builder
   plus three new placeholders (`__BB_PUBLIC_URL__` already existed):
   - `__BB_SCHEDULER_URL__` → `https://$PUBLIC_HOSTNAME:7982`
   - `__BB_OIDC_ISSUER__` → `https://$PUBLIC_HOSTNAME:5556`
   The builder hard-codes `useIdTokenClaims: {}`, scopes
   `[openid, email, profile, groups, offline_access]`, and the
   `metadataExtractionJmespathExpression`
   `{"public": {"username": preferred_username, "email": email, "groups": groups}}`.

2. **`compose/config/browser.jsonnet`** — `httpServers[0].
   authenticationPolicy = common.oidcAuth(...)` with `clientId='bb-browser'`,
   secrets pulled from `__BB_BROWSER_OIDC_CLIENT_SECRET__` /
   `__BB_BROWSER_COOKIE_SEED__`, redirect to
   `common.browserUrl + '/oidc-callback'`.

3. **`compose/config/scheduler.jsonnet`** — same pattern on
   `adminHttpServers[0]` with `clientId='bb-scheduler-admin'`.
   Other gRPC servers (clientGrpc, workerGrpc, buildQueueStateGrpc)
   stay `allow{}` — they are not user-facing.

4. **`compose/docker-compose.yml`** — `dex.networks.default.aliases:
   [bb-psmdb.ddns.net]` (see choice #3 above).

5. **`scripts/create-central.sh`**:
   - `bake_env` generates `BB_BROWSER_COOKIE_SEED` and
     `BB_SCHED_COOKIE_SEED` (`openssl rand -hex 32`) and persists
     them in `.env` alongside the OIDC client secrets, with the same
     "preserve across re-runs" semantics (rotating either invalidates
     all live sessions).
   - sed-replace pass for all six new placeholders, followed by an
     anti-regression `grep -RIl '__BB_[A-Z_]*__'` that fails the
     deploy if any token survived.
   - Smoke test loops over `[browser:7984:bb-browser,
     scheduler:7982:bb-scheduler-admin]` and asserts each `/` returns
     a 302 to `https://$PUBLIC_HOSTNAME:5556/auth?...client_id=<expected>...`.
     A 200 here would mean the OIDC placeholders weren't replaced and
     BB silently fell back to allow{}.

#### Verification

- [x] `curl -sI https://bb-psmdb.ddns.net:7984/` → `302 location:
      https://bb-psmdb.ddns.net:5556/auth?client_id=bb-browser&...`
      (covered by `create-central.sh` smoke test on every redeploy)
- [x] `curl -sI https://bb-psmdb.ddns.net:7982/` → `302 location:
      https://bb-psmdb.ddns.net:5556/auth?client_id=bb-scheduler-admin&...`
      (covered by `create-central.sh` smoke test on every redeploy)
- [ ] Browser end-to-end (manual, one-time after Step 4 deploy): open
      `https://bb-psmdb.ddns.net:7984/`, click through GitHub consent →
      land on bb-browser UI. Repeat for `:7982/`.
- [ ] Non-team-member account hits "User not in any required org/team"
      page at Dex `/callback` and never reaches BB. (Manual; needs an
      account that's NOT in build-engineers/iit/dev-psmdb.)

### Step 5 — JWT for Bazel clients via Dex Device Code flow (server side) — DONE

**Architecture decision change vs. the original draft**: the first plan
proposed minting our own RSA JWT via a `scripts/issue-rbe-jwt.sh` utility
(static keypair, manual `kid` rotation, secret distribution). We replaced
this with a **Dex-issued OIDC token** via the OAuth 2.0 Device
Authorization Grant (RFC 8628). Reasons:

- **No new key material**. Dex is already running for the UIs (Step 3 + 4)
  and already owns a JWT signing key (rotated every 6 h, last 24 h kept
  in `/keys`). Reusing it eliminates the parallel "RBE-only" key universe.
- **Auto-refresh, no quarterly rotation drama**. Tokens are short-lived
  (1 h `id_token` + 90 d sliding refresh) and refreshed silently by the
  Bazel wrapper. There is no "issue 10-20 tokens by hand every 90 days"
  ritual.
- **Same identity model as the UIs**. `sub` and `groups` claims come from
  GitHub via Dex's connector — the same allow-list (Percona orgs +
  build-engineers / iit / dev-psmdb teams) that gates bb-browser /
  bb-scheduler-admin gates Bazel access. One source of truth.
- **Revocation = remove from the GitHub team**. No "rotate `kid`,
  redistribute to N people" emergency procedure.
- **Headless / SSH-only machines work** via the Device Code flow
  (RFC 8628): the wrapper prints a `https://bb-psmdb.ddns.net:5556/device`
  URL + a short user_code; the engineer logs in on any browser-capable
  device, the wrapper polls Dex's `/token` endpoint, and the build
  proceeds. No in-tunnel browser required.

This step covers **only the server side** (Dex + Envoy). The client
side (wrapper_hook + `bazel-rbe-login` CLI) is Step 5b in the
`percona-server-mongodb` repo.

**Goal**: every Bazel client must present a valid signed JWT issued by
Dex; Envoy validates it via `remote_jwks` against Dex's `/keys`. The BB
frontend itself stays `allow{}` because all traffic to it has already
been authenticated upstream.

#### 5.1 Dex — `bazel-cli` public client (Device Code grant)

Add a third static client to `compose/dex/dex.yaml` next to
`bb-browser` and `bb-scheduler-admin`:

```yaml
- id: bazel-cli
  name: 'Bazel RBE CLI'
  public: true
  redirectURIs:
  - urn:ietf:wg:oauth:2.0:oob
```

- `public: true` — no `secretEnv`. Bazel clients run on developer
  machines / CI runners; we cannot safely ship a client secret there.
  Security comes from PKCE (mandatory in Dex when there is no password
  connector) plus the team-membership gate in the GitHub connector
  (a stolen `device_code` is useless without also passing GitHub OAuth
  as a member of one of the allowed teams).
- `redirectURIs` — Device Code flow does not use them, but Dex's
  static-client validation requires at least one. The
  `urn:ietf:wg:oauth:2.0:oob` placeholder makes it explicit that no
  real callback URL is expected.
- Dex enables the device-code grant on every public client by default;
  no extra `oauth2.grantTypes` is needed.

#### 5.2 Envoy — `jwt_authn` + `remote_jwks` against Dex

Patch `IaC/buildbarn/reapi-proxy/envoy.yaml`:

```yaml
http_filters:
- name: envoy.filters.http.jwt_authn
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.JwtAuthentication
    providers:
      dex_provider:
        issuer: https://bb-psmdb.ddns.net:5556
        audiences: [bazel-cli]
        remote_jwks:
          http_uri:
            uri: https://bb-psmdb.ddns.net:5556/keys
            cluster: dex_jwks
            timeout: 5s
          cache_duration: 600s
        forward: true
        from_headers:
        - name: authorization
          value_prefix: "Bearer "
    rules:
    - match: { prefix: "/" }
      requires: { provider_name: dex_provider }
- name: envoy.filters.http.router
  ...
```

Plus a new `dex_jwks` upstream cluster pointing at the
`bb-psmdb.ddns.net` docker network alias (added on the Dex service in
Step 4) on port 5556, with TLS upstream context, SNI =
`bb-psmdb.ddns.net`, and `validation_context.trusted_ca` =
`/etc/ssl/certs/ca-certificates.crt` (Let's Encrypt R10/R11 is in the
system bundle). Pinning SAN match to `bb-psmdb.ddns.net` prevents an
upstream impersonation attack from succeeding even if a different cert
ever ended up trusted in the bundle.

`forward: true` keeps the Authorization header attached when Envoy
forwards to BB. BB does not validate it today (frontend stays
`allow{}` on the docker bridge), but leaving it in the request lets us
turn on BB-side JWT validation as defense-in-depth later without
re-shipping Envoy.

#### 5.3 Audience pinning

`audiences: [bazel-cli]` in the jwt_authn provider means a token minted
for `bb-browser` or `bb-scheduler-admin` (different `aud`) cannot be
replayed against the gRPC endpoint, even though all three are signed
by the same Dex key. This is a defense-in-depth against e.g. a
developer accidentally pasting their UI session's id_token into
`--remote_header`.

#### 5.4 Smoke tests added to `create-central.sh`

- `GET /keys` on `https://bb-psmdb.ddns.net:5556` returns a JWKS with
  at least one key (`.keys | length > 0`). An empty set means Envoy
  jwt_authn rejects every RPC.
- `grpcurl -insecure -d {} 127.0.0.1:8981 build.bazel.remote.execution.v2.Capabilities/GetCapabilities`
  from inside the scaler container (host networking, ships grpcurl)
  must respond with `Jwt is missing` / `Unauthenticated`. A 200 response
  here means jwt_authn is silently OFF.

#### 5.5 BB-side note (unchanged from original plan)

With Envoy enforcing the JWT, BB scheduler `clientGrpcServers` and
frontend `grpcServers` stay `allow{}` — Envoy is the only ingress to
them on this host. Optional defense-in-depth (BB also validating the
forwarded JWT) is deferred; current plan keeps BB `allow{}` and
documents that all gRPC auth lives in Envoy.

### Step 5b — Bazel client (`.bazelrc.psmdb` + `wrapper_hook.py`) — PR-READY

Tracked in a separate `percona-server-mongodb` repo PR (PSMDB-2043).
Server side (Step 5) is independently testable with `grpcurl` once a
developer has obtained a token via Dex's `/device/code` + `/token`
directly; the wrapper just automates that.

**What landed in PSMDB-2043** (one PR per branch, `v8.0` / `v8.3` /
`master`):

* `bazel/wrapper_hook/rbe_auth.py` — new module. Stdlib only
  (`urllib`, `json`, `ssl`, `base64`). Single entry-point
  `get_id_token()` with the four-tier fallback (cache → refresh →
  device-code on TTY → `RbeAuthRequired` non-TTY). Token cache at
  `~/.cache/rbe/token.json` mode 0600, atomic-rename writes.
  Constants `ISSUER` / `CLIENT_ID` / `AUDIENCE` hardcoded at the top
  of the file (variant D from the design discussion — one file to
  edit when the buildfarm migrates off `bb-psmdb.ddns.net`, no env
  var ceremony).
* `bazel/wrapper_hook/bazel-rbe-login` — standalone CLI. Modes:
  default (force fresh device-code flow), `--status`, `--logout`,
  `--print-token` (handy for `grpcurl` smoke tests).
* `bazel/wrapper_hook/wrapper_hook.py` — hook in `main()`. When the
  current build invocation contains `--config=psmdb_buildfarm`,
  fetch the token and `append_args(args,
  ["--remote_header=authorization=Bearer <token>"])` before writing
  the final args file. Failure modes return a friendly `_info()`
  line and `sys.exit(4)` rather than letting Bazel run the build
  unauthenticated and fail every action with Envoy 401s.
* `.bazelrc.psmdb` — endpoint flipped from
  `grpc://<central-primary-ip>:8981` (rotating primary IP, plain gRPC) to
  `grpcs://bb-psmdb.ddns.net:8981` (TLS, hostname pinned to the
  Hetzner Floating IP).

**Explicitly not in PSMDB-2043 (deferred)**:

* No `--remote_header` line in `.bazelrc.psmdb`. The token is
  per-user, lives 1 h, and committing it would defeat the point.
* No proactive expiry warnings in `wrapper_hook.py`. Users only see
  the prompt when their build is actually blocked, same UX as
  `gh auth login`.
* Jenkins service-account flow → Step 5c.

In every PSMDB branch (`v8.0`, `v8.3`, `master`):

```
build:psmdb_buildfarm --remote_executor=grpcs://bb-psmdb.ddns.net:8981
build:psmdb_buildfarm --remote_cache=grpcs://bb-psmdb.ddns.net:8981
# Authorization header injected by wrapper_hook from ~/.cache/rbe/token.json
```

`wrapper_hook.py` extension (`bazel/wrapper_hook/rbe_auth.py`) does:

1. Look for `~/.cache/rbe/token.json` (mode 0600): `{access_token,
   id_token, refresh_token, expires_at}`.
2. If `id_token` is still valid (with 60 s skew margin), inject
   `--remote_header=authorization=Bearer <id_token>` into the Bazel
   argv and continue.
3. If expired but `refresh_token` is present, exchange it at
   `https://bb-psmdb.ddns.net:5556/token` (silent), update
   `token.json`, inject, continue.
4. If `refresh_token` is missing/rejected and stdin is a TTY: start
   the Device Authorization Grant — print the URL + user_code on
   stderr (no fancy "your token expires in 7 days" preamble; users
   only see the prompt when their build is actually blocked), poll
   `/token` every `interval` seconds until success / denial / timeout,
   persist tokens, inject, continue.
5. Non-TTY (e.g. Jenkins, deferred to Step 5c): fail fast with a
   short error pointing at the standalone `bazel-rbe-login` tool —
   no interactive flow attempted.

A standalone `bazel-rbe-login` utility lives next to `wrapper_hook.py`
for explicit re-auth ahead of a build (e.g. when a user knows their
refresh token has been revoked).

The wrapper does **not** scan stderr for 401s or print proactive token
expiry warnings. If a build fails with a 401-equivalent gRPC status,
the user re-runs `bazel-rbe-login` and tries again — same UX as a
GitHub `gh` re-auth.

#### 5d — Worker bypass (Option C) — DONE

**Symptom (E2E test 2026-04-28):** With Steps 1+5 deployed, the first
`bazel build --config=psmdb_buildfarm install-dist-test` from a fresh
laptop got 10 437 cache hits on the unary CAS/AC path through Envoy
(JWT validated, TLS terminated — exactly Step 5's contract), then
**every remote-execution attempt** failed with:

```
Remote Execution Failure: Unavailable: Failed to obtain input directory ".":
connection error: desc = "error reading server preface: unexpected EOF"
```

**Root cause:** Bazel client → Envoy → frontend works fine. But the
**worker** also has to fetch action inputs from CAS, and our worker
config (`worker/config/common.libsonnet` from the PSMDB-2040 design)
pointed those reads at the **same Envoy listener on `:8981`**:

```
contentAddressableStorage: { grpc: { client: { address: '__CENTRAL_PRIVATE_IP__:8981' } } }
actionCache:               { grpc: { client: { address: '__CENTRAL_PRIVATE_IP__:8981' } } }
fileSystemAccessCache:     { grpc: { client: { address: '__CENTRAL_PRIVATE_IP__:8981' } } }
```

That was harmless before Step 5 (Envoy was a transparent passthrough).
After Step 5, Envoy `:8981` requires:
* TLS (worker would need to trust our self-signed cert), and
* a Dex-issued OIDC bearer token in `authorization: Bearer …`.

Workers are headless ondemand VMs spawned by `scaler/bootstrap.py`.
They have neither. The plaintext gRPC handshake into a TLS listener
manifests as "unexpected EOF" at HTTP/2 framing time — Envoy drops
the TCP connection because byte 0 isn't a valid TLS ClientHello.

**Why not just give workers a JWT:** would have meant either
(a) provisioning a long-lived service-account token to every spawned
VM (key-distribution problem we don't currently have), or
(b) adding `oauth2-token-source` plumbing to `bb-runner` and a Dex
client-credentials flow. Both add ~hours of build time across thousands
of remote actions for the TLS handshake alone, with no security gain
because the workers already live behind the Hetzner private network
perimeter.

**Fix (Option C — "workers bypass Envoy"):** route worker→CAS over
the trusted private hop, leave Envoy purely as the public auth gateway.

* `compose/docker-compose.yml` — bb-frontend already had
  `expose: 8980` (intra-compose). **Added** a host port mapping
  `${PRIVATE_IP}:8980:8980` so the same listener is reachable from
  worker VMs over the Hetzner private interface, but **NOT** on
  the public IP.
* `worker/config/common.libsonnet` — flipped CAS / AC / FSAC
  `address` from `__CENTRAL_PRIVATE_IP__:8981` to
  `__CENTRAL_PRIVATE_IP__:8980`. Updated the file header to spell
  out the security reasoning so the next person editing it doesn't
  "fix" it back.
* `scripts/create-central.sh` — new smoke test asserts:
  `:8980 reachable on $PRIVATE_IP`, `:8980 NOT reachable on
  $PUBLIC_IP` (proves we didn't accidentally re-expose CAS to
  the public Internet).

**Auth posture after 5d:**

| Path                         | Listener         | TLS | Auth         | Why |
|------------------------------|------------------|-----|--------------|-----|
| Bazel client → CAS/AC        | Envoy `:8981`    | yes | Dex JWT      | public Internet |
| Bazel client → executor      | Envoy `:8981`    | yes | Dex JWT      | public Internet |
| Worker → CAS/AC/FSAC         | frontend `:8980` | no  | network only | Hetzner private subnet |
| Worker → scheduler           | scheduler `:8983`| no  | network only | Hetzner private subnet |
| `frontend` → storage shards  | `storage-N:8981` | no  | none         | docker bridge only |

The "network only" hops are protected by Hetzner Cloud Firewall + the
private-network ACL (Step 6 will tighten the FW rules; the network
itself is already isolated to the `psmdb.cd` cloud network).

**Verification on `master`:**
```
INFO: Elapsed time: 361.588s, Critical Path: 332.49s
INFO: 18209 processes: 10437 remote cache hit, 5967 internal, 1803 local, 2 remote.
INFO: Build completed successfully, 18209 total actions
```

The `2 remote` count is the new evidence — those are actions that
actually went to a freshly-spawned worker VM, fetched inputs from
`frontend:8980` over the private IP, executed, and uploaded outputs
back. Previously every "remote execution" attempt hit the EOF.

**Operational note:** existing idle workers carry the OLD
`common.libsonnet` (with `:8981`). On a Step-5d redeploy you must
either (a) wait ~10 min for the scaler's idle reaper, or (b) delete
them via `hcloud server delete` from the operator's laptop. Spawned
workers AFTER the redeploy automatically get the new config because
`scaler/bootstrap.py` re-renders user-data from
`/var/lib/buildbarn/worker/` on every spawn.

#### 5b.1 Jenkins — deferred (Step 5c)

The Device Code flow assumes a human at a browser. For Jenkins jobs
we will issue a service-account refresh token via Dex's `/token`
endpoint with a long-lived client and store it as a Jenkins
credential. Tracked separately because it requires a different Dex
client config (`offline_access`, no PKCE) and a per-job rotation
policy that is out of scope for the human-developer Step 5b.

### Step 6 — Hetzner Cloud Firewall — DEFERRED

**Status:** intentionally **PENDING** as of 2026-04-29. The
authentication / TLS pipeline (Steps 1-5d) already gates every public
endpoint at the application layer (TLS + Dex OIDC for UIs / JWT for
Bazel clients), so the network ACL is hardening-on-top, not a missing
foundation. Locking the FW down today would also lock in three
artifacts that are likely to change soon:

1. **Upstream merge.** The PSMDB-2034 / PSMDB-2040 / PSMDB-2043 work
   is currently living on Percona's `vorsel/percona-server-mongodb`
   fork + `percona/jenkins-pipelines` private branch. Once that is
   merged upstream / into Percona main, the public surface (which
   Jenkins runners contact this RBE from, what egress IPs we need to
   allowlist for SSH, etc.) is more settled.

2. **Production URI / domain.** We're on `bb-psmdb.ddns.net` (No-IP
   free DDNS) for the dev cluster. When this graduates, Percona will
   provision a `.percona.com` (or similar) hostname and Let's Encrypt
   cert, and SSH ACLs will pivot to the corp VPN CIDRs. Pinning the
   firewall now would just create a re-do task at promotion.

3. **Floating IP.** The Floating IP (recorded in
   `INFRASTRUCTURE.md`, exposed as `${PUBLIC_IP}` in `.env`) is
   attached to this dev central VM. It's stable across VM redeploy
   *of this VM*, but not across an account / project
   migration to the Percona Hetzner tenant — which is the most likely
   path to production. The FW rules would have to be re-keyed against
   the new IP/network anyway.

**What the firewall WILL look like** when we do come back to this
(target shape, not currently applied):

Create one firewall (`rbe-central-fw`) attached to the central VM:

| Port | Proto | Source | Purpose |
|---|---|---|---|
| 80   | TCP | 0.0.0.0/0 | ACME HTTP-01 renewal (Let's Encrypt) |
| 5556 | TCP | 0.0.0.0/0 | Dex OIDC IdP |
| 7982 | TCP | 0.0.0.0/0 | bb-scheduler admin UI (TLS + OIDC) |
| 7984 | TCP | 0.0.0.0/0 | bb-browser UI (TLS + OIDC) |
| 8981 | TCP | 0.0.0.0/0 | Envoy → BB frontend gRPC (TLS + JWT) |
| 22   | TCP | Percona VPN/office CIDRs | SSH |
| (other) | — | DROP | default deny |

Internal (private network — `psmdb.cd` Hetzner cloud network, no
firewall on the worker side beyond the implicit network-level
isolation):
- Worker VMs reach scheduler `:8983` and frontend `:8980` over the
  Hetzner private network only.
- `:8984` BuildQueueState bound to `127.0.0.1`, used by `scaler.py`
  on the central host itself.

**Trigger to revisit:** any one of (a) PSMDB-2034 family merged
upstream, (b) production hostname / cert provisioned, (c) project
migrated off the personal Hetzner account.

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
  account owner (the address in `${LE_EMAIL}`) asking to confirm the hostname is still
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
| 3 | **Hetzner Floating IP** attached to the central VM, persistent via `/etc/network/interfaces.d/60-floating-ip.cfg`. DNS A-record points at the FI, not at the VM's primary IP. (Live IP value lives in `INFRASTRUCTURE.md` / `${PUBLIC_IP}` in `.env`.) | Decouples the public-facing IP from VM lifecycle. Recreating the central VM no longer churns DNS / cert / OAuth callback URLs — just `hcloud floating-ip assign` after `create-central.sh`. Cost: €1/month per IP. |
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
| 6 | **JWT lifetime / rotation = Dex-issued OIDC token, NOT static signing key** (1 h `id_token` + 90 d sliding refresh, key `kid` rotated by Dex every 6 h) | First draft proposed a per-deployment RSA-2048 keypair + `scripts/issue-rbe-jwt.sh` + 90 d / quarterly rotation. Reusing Dex eliminates that key universe entirely: same identity model as the UIs (GitHub team gate), automatic refresh in the wrapper, revocation = remove from GitHub team. Headless / SSH-only machines work via Device Authorization Grant (RFC 8628) — print URL + user_code on stderr, poll `/token` until login completes on a separate browser-capable device. |
| 7 | **No proactive token-expiry warnings in `wrapper_hook.py` for human users** | First draft of Step 5b suggested printing "your token expires in 7 days" notices. Removed — human developers only see the prompt when their build is actually blocked, same UX as a `gh auth login` re-prompt. Token monitoring on Jenkins is a separate concern (Step 5c, deferred). |
| 8 | **`envoy-proxy` MUST restart on `envoy.yaml` change** | Initially excluded from `create-central.sh`'s `docker compose restart` list under the (wrong) assumption that "reapi-proxy + envoy configs are baked at build time". `envoy.yaml` is bind-mounted; `compose up -d` doesn't pick up bind-mount file changes. Bit us briefly during Step 5 testing where edits to the jwt_authn filter weren't picked up. The path `/var/lib/buildbarn/reapi-proxy/envoy.yaml` is misleading too — the file is the **envoy** proxy's config, not reapi-proxy's. |
| 9 | **Dex `bazel-cli` static client MUST list `/device/callback` in `redirectURIs`** (in addition to `urn:ietf:wg:oauth:2.0:oob`) | Dex's Device Code handler does NOT special-case `/device/callback` in the redirect-URI validator. When the user opens `/device`, picks GitHub, and gets bounced through GitHub OAuth, Dex starts an *internal* OIDC flow with `redirect_uri=/device/callback` (its own handler that finishes the device-code → id_token exchange) and validates THAT against the same `staticClients[].redirectURIs` list as any other OAuth flow. Without it the GitHub-login step ends with `Bad Request: Unregistered redirect_uri ("/device/callback")`. This is a Dex-side wart and is documented inside `dex.yaml` next to the field. |

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
