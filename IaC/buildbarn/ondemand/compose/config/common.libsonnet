// Shared helpers used by frontend / scheduler / browser / storage jsonnet configs.
//
// Derived from buildbarn/bb-deployments @ 4da3878
// (docker-compose/config/common.libsonnet), adapted for PSMDB ondemand:
//
//   * `browserUrl` carries the token `__BB_PUBLIC_URL__`, which the
//     bootstrap script (scripts/create-central.sh) sed-replaces with
//     the actual public URL of the central VM once it's been created.
//     We use a placeholder because the public IP isn't known at commit
//     time.
//
//   * `maximumMessageSizeBytes` and sharding layout are unchanged from
//     upstream — storage-0 and storage-1 are the two sibling services
//     in our docker-compose.yml.
{
  blobstore: {
    contentAddressableStorage: {
      sharding: {
        shards: {
          '0': {
            backend: { grpc: { client: { address: 'storage-0:8981' } } },
            weight: 1,
          },
          '1': {
            backend: { grpc: { client: { address: 'storage-1:8981' } } },
            weight: 1,
          },
        },
      },
    },
    actionCache: {
      completenessChecking: {
        backend: {
          sharding: {
            shards: {
              '0': {
                backend: { grpc: { client: { address: 'storage-0:8981' } } },
                weight: 1,
              },
              '1': {
                backend: { grpc: { client: { address: 'storage-1:8981' } } },
                weight: 1,
              },
            },
          },
        },
        maximumTotalTreeSizeBytes: 64 * 1024 * 1024,
      },
    },
  },
  fileSystemAccessCache: {
    sharding: {
      shards: {
        '0': {
          backend: { grpc: { client: { address: 'storage-0:8981' } } },
          weight: 1,
        },
        '1': {
          backend: { grpc: { client: { address: 'storage-1:8981' } } },
          weight: 1,
        },
      },
    },
  },
  browserUrl: '__BB_PUBLIC_URL__',
  maximumMessageSizeBytes: 2 * 1024 * 1024,
  global: {
    diagnosticsHttpServer: {
      httpServers: [{
        listenAddresses: [':80'],
        authenticationPolicy: { allow: {} },
      }],
      enablePrometheus: true,
      enablePprof: true,
      enableActiveSpans: true,
    },
  },
}
