// bb-portal — Build observability UI: ingests Bazel's Build Event
// Stream over gRPC, persists invocations/actions/targets to Postgres,
// and serves a Next.js UI (proxied through the Go backend).
//
// See buildbarn-portal-plan.md (this directory's parent) for the
// architectural rationale; see buildbarnrepos/bb-portal/config/portal.jsonnet
// (cloned at /Users/.../buildbarnrepos/bb-portal/) for the full upstream
// example this is shaped from. Field names map to
// pkg/proto/configuration/bb_portal/bb_portal.proto.
//
// PHASE 2a SHAPE (wire-up, no deprecation — see plan §"Phase 2 —
// Deprecation roadmap"):
//
//   * besServiceConfiguration   — ENABLED. Owns BES gRPC ingest on :8082
//     and the Postgres pool that persists everything.
//   * httpServers (UI on :8081) — ENABLED. OIDC via Dex, same pattern as
//     bb-browser / bb-scheduler-admin.
//   * browserServiceConfiguration   — ENABLED. Reverse-proxies /browser/*
//     gRPC-Web traffic to frontend:8980 (CAS / AC / FSAC). The standalone
//     bb-browser :7984 stays live in parallel — operators can use either
//     UI during the soak period.
//   * schedulerServiceConfiguration — ENABLED. Reverse-proxies
//     /scheduler/* gRPC-Web traffic to scheduler:8984. The standalone
//     bb-scheduler-admin :7982 stays live in parallel.
//
// Phase 2c (separate plan-update — TODO) deletes the standalone services
// once bb-portal has been the daily driver for ≥1 week without operator
// complaints. Until then, three UIs answer in parallel.
local common = import 'common.libsonnet';

{
  // Common Buildbarn diagnostics (Prometheus exporter on :80, pprof,
  // active spans). NB: we do NOT run a Prometheus scraper today —
  // see plan §"Phase 2 — Deprecation roadmap" footnote. The endpoint
  // is here for future use and ad-hoc `curl :80/metrics` during
  // incident response.
  global: common.global,

  // Reverse-proxy target for non-API HTTP requests: Next.js frontend
  // container, accessible by service name on the docker bridge
  // network (compose/docker-compose.yml :: bb-portal-frontend, port
  // 3000 internal-only). All gRPC-Web / GraphQL / OIDC redirect
  // traffic stays on the backend at :8081 below; everything else
  // (the actual Next.js UI bundle) gets proxied here.
  frontendProxyUrl: 'http://bb-portal-frontend:3000',

  // CORS allow-list — the public origin operators hit. Without this,
  // gRPC-Web XHRs from the frontend to the backend's :8081 surface
  // get rejected at the browser. Single-origin (frontend and backend
  // share the same public hostname:port pair via the reverse proxy),
  // which is the simplest secure config.
  allowedOrigins: [common.portalUrl],

  maximumMessageSizeBytes: common.maximumMessageSizeBytes,

  httpServers: [{
    listenAddresses: [':8081'],
    // TLS termination on the public-facing side. Same Let's Encrypt
    // cert + refresh strategy as bb-browser / bb-scheduler-admin —
    // helper defined in common.libsonnet.
    tls: common.serverTls,
    // OIDC delegation to Dex. Mirrors bb-browser's posture exactly:
    //   1. Anonymous request → 302 to Dex /auth?client_id=bb-portal
    //   2. Dex enforces percona:build-engineers team membership at
    //      its GitHub /callback (see compose/dex/dex.yaml :: orgs[].teams[])
    //   3. Successful login → /oidc-callback here, BB exchanges code
    //      for token over TLS, drops the AES-GCM session cookie.
    //
    // Both placeholders below are sed-replaced by
    // create-central.sh::bake_env() from .env (mode 0600). They are
    // generated once via `openssl rand -hex 32` and PRESERVED across
    // re-runs to avoid silently invalidating live operator sessions.
    authenticationPolicy: common.oidcAuth(
      clientId='bb-portal',
      clientSecret='__BB_PORTAL_OIDC_CLIENT_SECRET__',
      redirectUrl=common.portalUrl + '/oidc-callback',
      cookieSeed='__BB_PORTAL_COOKIE_SEED__',
    ),
  }],

  // Per-instance authorisation gate. We keep `allow: {}` because the
  // bb-portal UI does not currently scope by REAPI instance_name —
  // the single PSMDB build farm uses `hardlinking` as its sole
  // instance name (see .bazelrc.psmdb :: --remote_instance_name).
  // If we ever multi-tenant this portal, this is the layer where
  // org-level filtering plugs in.
  instanceNameAuthorizer: { allow: {} },

  besServiceConfiguration: {
    // BES gRPC ingest endpoint. Bazel clients connect to the public
    // Envoy listener on :1985 (TLS + JWT terminated by Envoy via the
    // existing `dex_provider` jwt_authn filter — same provider used
    // for :8981 Bazel-execution traffic), Envoy forwards plaintext
    // gRPC here. Trust posture: `allow: {}` because Envoy already
    // authenticated the bearer. See plan §"Step 1 → Decision B" for
    // the rationale (Envoy passthrough vs cron-fetched JWKS file).
    grpcServers: [{
      listenAddresses: [':8082'],
      authenticationPolicy: { allow: {} },
      // Bazel BES events on a busy PSMDB build can hit a few MB per
      // batch (test summaries, file fingerprints). 10 MiB gives
      // headroom — same value as upstream's portal.jsonnet sample.
      maximumReceivedMessageSizeBytes: 10 * 1024 * 1024,
    }],

    // Postgres connection. Host `bb-portal-db` resolves on the
    // docker compose default bridge (the service name). Password is
    // sed-replaced from .env (BB_PORTAL_DB_PASSWORD, openssl rand
    // -hex 32, preserved across re-runs in bake_env). sslmode=disable
    // because both endpoints live on the same docker bridge and
    // never leave the host — TLS would only add CPU.
    database: {
      postgres: {
        connectionString:
          'postgresql://bbportal:__BB_PORTAL_DB_PASSWORD__@bb-portal-db:5432/bbportal?sslmode=disable',
      },
      // Pool sizing — upstream-recommended values from the proto
      // comments. Worth revisiting once we see actual concurrent
      // BES streams under PSMDB CI load.
      connectionPoolConfiguration: {
        maxOpenConnections: 10,
        maxIdleConnections: 10,
        connectionMaxLifetime: '120s',
        connectionMaxIdleTime: '30s',
      },
    },

    // BEP file upload via the UI is a footgun: a developer could
    // upload stale events from their laptop and pollute the shared
    // history. We only want gRPC ingest from CI / Bazel via the
    // Envoy-validated :1985 path.
    enableBepFileUpload: false,

    // GraphQL playground would expose an unauthenticated schema
    // explorer. Useful in dev, off in prod.
    enableGraphqlPlayground: false,

    // basicAndTarget keeps invocation + per-target metadata. The
    // alternative (`basic`) drops target rows, which would make the
    // "this build failed because target X failed" use case impossible.
    saveDataLevel: { basicAndTarget: {} },

    databaseCleanupConfiguration: {
      cleanupInterval: '60s',
      invocationMessageTimeout: '3600s',
      // 30 days of invocation retention — see plan §"Out of scope"
      // for the rationale. 30d × ~20 MB/day = ~600 MB DB ceiling.
      invocationRetention: '2592000s',
    },

    minEventBatchDuration: '0.1s',
  },

  // Phase 2a wiring — bb-portal now serves /browser and /scheduler
  // routes alongside the standalone bb-browser :7984 / bb-scheduler-admin
  // :7982 services. Operators can use either UI during the soak period;
  // Phase 2c (TODO) retires the standalone services. See plan
  // §"Phase 2 — Deprecation roadmap".
  //
  // CAS / AC / FSAC backends point at the existing bb-frontend service
  // (compose/config/frontend.jsonnet, listenAddresses :8980 wildcard).
  // Same shard-cluster the bb-browser :7984 service already uses, so
  // both UIs see identical blob views.
  //
  // initialSizeClassCache is INTENTIONALLY UNSET. Our frontend.jsonnet
  // doesn't expose an ISCC backend (only CAS/AC/FSAC, matching upstream
  // bb-deployments shape). Setting `initialSizeClassCache: { grpc: { ...
  // frontend:8980 } }` here would make bb-portal route ISCC RPCs to
  // frontend, which would 404 them — UI errors instead of graceful
  // empty state. Effect of leaving unset: BrowserPreviousExecutionsPage
  // shows "no previous-execution stats" — Bazel size-estimate visibility
  // is gone, but action timelines, test results, blob inspection, and
  // scheduler views all work. Track separately if size estimates become
  // important; we'd need to stand up a dedicated ISCC backend service.
  browserServiceConfiguration: {
    contentAddressableStorage: { grpc: { client: { address: 'frontend:8980' } } },
    actionCache: { grpc: { client: { address: 'frontend:8980' } } },
    fileSystemAccessCache: { grpc: { client: { address: 'frontend:8980' } } },
  },

  // schedulerServiceConfiguration — points at the buildQueueState gRPC
  // server inside the scheduler container (scheduler.jsonnet ::
  // buildQueueStateGrpcServers, listenAddresses :8984 wildcard).
  // killOperationsAuthorizer `allow: {}` because users are already
  // OIDC-authenticated by the httpServers entry above (Dex enforces
  // percona:build-engineers team membership at /callback). If we ever
  // need a per-instance kill gate, plug it in here.
  // listOperationsPageSize: 500 — proto-recommended value; tunable.
  schedulerServiceConfiguration: {
    buildQueueStateClient: { address: 'scheduler:8984' },
    killOperationsAuthorizer: { allow: {} },
    listOperationsPageSize: 500,
  },
}
