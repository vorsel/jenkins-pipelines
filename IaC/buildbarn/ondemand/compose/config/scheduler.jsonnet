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
// from compose/config/ondemand-pools.yaml. See that file for the priming
// flow and the MAINTENANCE CONTRACT below. Ships as a small JSON array of
// PredeclaredPlatformQueueConfiguration entries, one per pool with a
// non-null container_image_sha.
local predeclared = import 'predeclared.libsonnet';

{
  adminHttpServers: [{
    listenAddresses: [':7982'],
    authenticationPolicy: { allow: {} },
  }],
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
  // edit the YAML and redeploy. One entry is emitted per pool whose
  // `container_image_sha` is non-null (null scaffolds an inactive pool
  // that awaits priming — see ondemand-pools.yaml for the priming flow).
  //
  // `sizeClasses: [0]` is applied uniformly: our workers register with the
  // default size_class=0, and we don't use feedback-driven size
  // classification. See bb_scheduler.proto
  // PredeclaredPlatformQueueConfiguration.size_classes for the rationale.
  predeclaredPlatformQueues: predeclared,
}
