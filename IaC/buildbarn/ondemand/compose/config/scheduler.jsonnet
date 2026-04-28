// Scheduler — the operation queue. Routes actions from frontend (gRPC :8982)
// to workers (gRPC :8983), exposes a programmatic queue-state API (:8984) for
// the ondemand scaler daemon, and serves an HTML admin UI (:7982) for humans.
//
// Derived from buildbarn/bb-deployments @ 4da3878 (docker-compose/config/scheduler.jsonnet).
// PSMDB-specific additions:
//   * `predeclaredPlatformQueues` — see comment near that field below.
// Port visibility (public / private / localhost) is controlled in docker-compose.yml,
// NOT here.
local common = import 'common.libsonnet';
// Generated at deploy time by create-central.sh's bake_predeclared() step
// from compose/config/ondemand-pools.yaml. See that file for the
// MAINTENANCE CONTRACT and the cross-release coexistence model. Ships as
// a small JSON array of PredeclaredPlatformQueueConfiguration entries —
// one per pool, with `container-image` property set to
// `docker://<runner_image>` taken verbatim from the YAML.
local predeclared = import 'predeclared.libsonnet';

{
  adminHttpServers: [{
    listenAddresses: [':7982'],
    // TLS — cert/key from the volume-mounted /etc/buildbarn/certs/, hot-
    // reloaded every refreshInterval (1h).
    tls: common.serverTls,
    // OIDC delegation to Dex (mirrors browser.jsonnet — see that file
    // for the rationale behind each oidcAuth() argument). The admin UI
    // at :7982 is a separate origin from bb-browser at :7984 (different
    // ports = different origins per RFC 6265), so users WILL log in
    // twice (once per UI). That's acceptable for the operator audience
    // — they hit scheduler-admin rarely and the round-trip is a few
    // seconds with an active GitHub session.
    //
    // The `bb-scheduler-admin` clientId / secret pair is registered as
    // a SEPARATE staticClient in dex.yaml from `bb-browser` so the
    // services have independent credentials — a leaked cookie/secret
    // on one UI doesn't compromise the other.
    authenticationPolicy: common.oidcAuth(
      clientId='bb-scheduler-admin',
      clientSecret='__BB_SCHED_OIDC_CLIENT_SECRET__',
      redirectUrl=common.schedulerUrl + '/oidc-callback',
      cookieSeed='__BB_SCHED_COOKIE_SEED__',
    ),
  }],
  // The next three gRPC servers stay plaintext on purpose:
  //   * clientGrpc :8982 lives on the docker-compose default bridge
  //     and is reached only by the frontend container (no host port).
  //   * workerGrpc :8983 is bound to ${PRIVATE_IP} (Hetzner private
  //     network) and only the ondemand worker VMs in the same network
  //     can reach it.
  //   * buildQueueStateGrpc :8984 is bound to 127.0.0.1 and is consumed
  //     only by the scaler daemon running on this host.
  // None of them is reachable from the public internet; adding TLS here
  // would only add cert-rotation surface without security benefit.
  clientGrpcServers: [{
    listenAddresses: [':8982'],
    authenticationPolicy: { allow: {} },
  }],
  workerGrpcServers: [{
    listenAddresses: [':8983'],
    authenticationPolicy: { allow: {} },
  }],
  buildQueueStateGrpcServers: [{
    listenAddresses: [':8984'],
    authenticationPolicy: { allow: {} },
  }],
  browserUrl: common.browserUrl,
  contentAddressableStorage: common.blobstore.contentAddressableStorage,
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  global: common.global,
  executeAuthorizer: { allow: {} },
  modifyDrainsAuthorizer: { allow: {} },
  killOperationsAuthorizer: { allow: {} },
  synchronizeAuthorizer: { allow: {} },
  actionRouter: {
    simple: {
      platformKeyExtractor: { action: {} },
      invocationKeyExtractors: [
        { correlatedInvocationsId: {} },
        { toolInvocationId: {} },
      ],
      initialSizeClassAnalyzer: {
        defaultExecutionTimeout: '1800s',
        maximumExecutionTimeout: '7200s',
      },
    },
  },
  // If a platform queue sits with no registered workers for 15 min, drop its
  // queued actions. For ondemand this is our fail-fast in case the scaler
  // can't bring up a worker VM (quota, API error, etc.) — better for a Bazel
  // client to fail quickly than to block indefinitely.
  //
  // NB: This timeout does NOT apply to predeclaredPlatformQueues (below).
  // Those queues have `mayBeRemoved=false` internally, so they persist
  // forever. Actions submitted to them wait up to the action's own
  // maximumExecutionTimeout (7200s above) for a worker to arrive.
  platformQueueWithNoWorkersTimeout: '900s',

  // Predeclared platform queues — created at scheduler boot, exist
  // independently of worker registration.
  //
  // Purpose: dodge Bazel's FAILED_PRECONDITION on the first `Execute` call
  // against a cold scheduler. Without a predeclared queue, bb-scheduler
  // rejects Execute with "No workers exist for instance name prefix ..."
  // the instant a Bazel client connects and no worker has ever registered
  // the matching platform. Bazel's GrpcRemoteExecutor classifies that code
  // as PERMANENT_FAILURE and never retries, so the whole build dies on
  // action #1 (verified: https://github.com/bazelbuild/bazel/blob/master/
  // src/main/java/com/google/devtools/build/lib/remote/RemoteRetrier.java).
  //
  // Predeclared queues switch scheduler behaviour: Execute succeeds (action
  // is queued), the scaler sees queued>0 on its next poll, spawns a VM,
  // and the action runs once the worker registers — typically ~2 min later.
  // Bazel's default --remote_timeout (3600s) comfortably absorbs the wait.
  //
  // Source: bb-remote-execution bb_scheduler.proto, field #12
  //   PredeclaredPlatformQueueConfiguration predeclared_platform_queues = 12;
  //
  // MAINTENANCE CONTRACT: the list below is AUTO-GENERATED from
  // compose/config/ondemand-pools.yaml by create-central.sh's
  // bake_predeclared() step. Do NOT hand-edit predeclared.libsonnet —
  // edit the YAML and redeploy. One entry is emitted per pool, with
  // `container-image` property = `docker://<runner_image>` (verbatim
  // from the YAML's runner_image field).
  //
  // `sizeClasses: [0]` is applied uniformly: our workers register with the
  // default size_class=0, and we don't use feedback-driven size
  // classification. See bb_scheduler.proto
  // PredeclaredPlatformQueueConfiguration.size_classes for the rationale.
  predeclaredPlatformQueues: predeclared,
}
