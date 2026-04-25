// bb-worker configuration for the ondemand fleet.
//
// Based on the working barn-psmdb /root/bb-deployments/docker-compose/config/
// worker-hardlinking-ubuntu22-04.jsonnet. Kept as close to prod as reasonable
// so the same Bazel .bazelrc keeps matching — only the scheduler endpoint
// changes (now points at the ondemand central over the private network).
//
// Placeholders resolved at spawn time by scripts/spawn-worker.sh (manual
// path) or scaler/bootstrap.py:render_user_data() (autoscaler path). The
// two paths MUST substitute the same set — otherwise manual and scaler-
// spawned workers ship different configs.
//   __CENTRAL_PRIVATE_IP__   — scheduler endpoint (workers talk to it on :8983)
//   __POOL_NAME__            — e.g. "ubuntu-noble-x86_64__v8_3__9873907c9659"
//                              (for workerId.slot — used in scheduler UI to
//                              identify which pool a worker belongs to)
//   __WORKER_HOSTNAME__      — the Hetzner VM hostname (for workerId.hostname)
//   __BAZEL_POOL_VALUE__     — pool.bazel_pool_value from ondemand-pools.yaml:
//                              architecture label Bazel sends in platform
//                              property `Pool` (x86_64 / aarch64). MUST match
//                              what PSMDB's .bazelrc emits for this OS.
//   __CONTAINER_IMAGE__      — full `docker://...` routing key, derived from
//                              pool.runner_image in ondemand-pools.yaml:
//                                docker://ghcr.io/vorsel/psmdb-buildbarn-runners/<distro>-<arch>:<psmdb_version>-<git-sha>
//                              This is THE routing key — if it doesn't
//                              match the Bazel client's request byte-for-
//                              byte, the worker registers into a different
//                              platform queue than the one the client
//                              writes to, actions queue forever, and Bazel
//                              eventually times out with
//                              DEADLINE_EXCEEDED. The exact-match contract
//                              is enforced by bb-scheduler. The Bazel-side
//                              value comes from PSMDB fork's
//                              bazel/platforms/psmdb_rbe_containers.bzl;
//                              the worker-side value comes from this
//                              substitution; create-central.sh's
//                              bake_predeclared bakes a third copy into
//                              scheduler.jsonnet's predeclaredPlatformQueues.
//                              All three MUST agree.
local common = import 'common.libsonnet';

{
  blobstore: common.blobstore,
  browserUrl: common.browserUrl,
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  scheduler: { address: '__CENTRAL_PRIVATE_IP__:8983' },
  global: common.global,
  buildDirectories: [{
    native: {
      buildDirectoryPath: '/worker/build',
      cacheDirectoryPath: '/worker/cache',
      maximumCacheFileCount: 1000000,
      maximumCacheSizeBytes: 100 * 1024 * 1024 * 1024,
      cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
    },
    runners: [{
      endpoint: { address: 'unix:///worker/runner' },
      concurrency: 12,
      // Matches what Bazel clients already expect — keeping this value in
      // lockstep with the existing barn-psmdb worker means we don't have to
      // touch .bazelrc. If we later want to distinguish ondemand from
      // permanent workers, change here AND in the client config.
      instanceNamePrefix: 'hardlinking',
      platform: {
        // Property tuple below MUST match whatever Bazel sends in Execute
        // platform.properties — any divergence and the scheduler treats
        // this worker as a different queue than the client writes to.
        // See header for the spawn-time substitution contract.
        properties: [
          { name: 'Pool', value: '__BAZEL_POOL_VALUE__' },
          { name: 'container-image', value: '__CONTAINER_IMAGE__' },
          { name: 'dockerNetwork', value: 'standard' },
        ],
      },
      workerId: {
        datacenter: 'hel1',
        rack: 'ondemand',
        slot: '__POOL_NAME__',
        hostname: '__WORKER_HOSTNAME__',
      },
    }],
  }],
  inputDownloadConcurrency: 10,
  outputUploadConcurrency: 11,
  directoryCache: {
    maximumCount: 1000,
    maximumSizeBytes: 1000 * 1024,
    cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
  },
}
