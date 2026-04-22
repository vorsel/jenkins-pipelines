// Scheduler — the operation queue. Routes actions from frontend (gRPC :8982)
// to workers (gRPC :8983), exposes a programmatic queue-state API (:8984) for
// the ondemand scaler daemon, and serves an HTML admin UI (:7982) for humans.
//
// Derived from buildbarn/bb-deployments @ 4da3878 (docker-compose/config/scheduler.jsonnet).
// No PSMDB-specific changes yet. Port visibility (public / private / localhost)
// is controlled in docker-compose.yml, NOT here.
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
  platformQueueWithNoWorkersTimeout: '900s',
}
