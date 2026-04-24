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
  // MAINTENANCE CONTRACT: every pool in compose/config/ondemand-pools.yaml
  // MUST appear below with the SAME container-image SHA. create-central.sh
  // enforces this via a preflight check — if you see the check fail, copy
  // the pool's `container_image_sha` from the YAML into a new entry here,
  // matching the `Pool` + `dockerNetwork` properties a Bazel client actually
  // sends. (Capture them live with `grpcurl ... ListPlatformQueues` after
  // a successful build, in case PSMDB adds more platform properties.)
  //
  // TODO: when we outgrow 1–2 pools, replace this list with a generator
  // script that reads ondemand-pools.yaml and emits the jsonnet. Manual
  // sync is fine at this scale; error-prone once we're tracking 11.
  predeclaredPlatformQueues: [
    {
      // Pool ubuntu-noble-x86_64 (psmdb 8.3 actively developed).
      // Platform properties captured from a real Bazel Execute error log:
      //   FAILED_PRECONDITION: No workers exist for instance name prefix
      //   "hardlinking" platform {"properties":[
      //     {"name":"Pool","value":"x86_64"},
      //     {"name":"container-image","value":"docker://...@sha256:f1bd9610..."},
      //     {"name":"dockerNetwork","value":"standard"}]}
      instanceNamePrefix: 'hardlinking',
      platform: {
        properties: [
          { name: 'Pool', value: 'x86_64' },
          { name: 'container-image', value: 'docker://quay.io/mongodb/bazel-remote-execution@sha256:f1bd96104b3b8d33fff1500421917f3e15d9525795043e8d3f7f382e87c10002' },
          { name: 'dockerNetwork', value: 'standard' },
        ],
      },
      // Single uniform worker size (concurrency=12 in worker.jsonnet).
      // `0` means "unsized" — use when there is no feedback-driven size
      // classification. See bb_scheduler.proto PredeclaredPlatformQueueConfiguration.size_classes.
      sizeClasses: [0],
    },
  ],
}
