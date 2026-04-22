// bb-worker configuration for the ondemand fleet.
//
// Based on the working barn-psmdb /root/bb-deployments/docker-compose/config/
// worker-hardlinking-ubuntu22-04.jsonnet. Kept as close to prod as reasonable
// so the same Bazel .bazelrc keeps matching — only the scheduler endpoint
// changes (now points at the ondemand central over the private network).
//
// Placeholders resolved at spawn time by scripts/spawn-worker.sh:
//   __CENTRAL_PRIVATE_IP__   — scheduler endpoint (workers talk to it on :8983)
//   __POOL_NAME__            — e.g. "ubuntu-noble-x86_64" (for workerId.slot)
//   __WORKER_HOSTNAME__      — the Hetzner VM hostname (for workerId.hostname)
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
        properties: [
          { name: 'Pool', value: 'x86_64' },
          { name: 'container-image', value: 'docker://quay.io/mongodb/bazel-remote-execution@sha256:f1bd96104b3b8d33fff1500421917f3e15d9525795043e8d3f7f382e87c10002' },
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
