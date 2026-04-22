// Storage shard configuration (used by both storage-0 and storage-1 services).
//
// Derived from buildbarn/bb-deployments @ 4da3878, resized for a 750 GB xfs
// volume (Hetzner volume psmdb-buildbarn-cas-ondemand, ID 105484418). See
// buildbarn-ondemand-scaler.md §5.1 for sizing rationale.
//
// Per-shard budget (two shards total):
//   CAS blocks         : 330 GB  (×2 = 660 GB on disk)
//   CAS key_location   :   6 GB  (×2 =  12 GB)
//   AC  blocks         :  30 GB  (×2 =  60 GB)
//   AC  key_location   :   1 GB  (×2 =   2 GB)
//   FSAC blocks        :   2 GB  (×2 =   4 GB)
//   FSAC key_location  :  50 MB  (×2 = 100 MB)
//   ────────────────────────────────────────────
//   per shard          : 369 GB
//   both shards        : 738 GB
//   + xfs + persistent : ~742 GB  → fits 750 GB with ~8 GB headroom
//
// Ring buffer layout (oldBlocks + currentBlocks + newBlocks + spareBlocks = 38
// blocks per shard). At 330 GB, block size ≈ 8.7 GB (upstream default had
// ~5.25 GB per block for 200 GB). Larger blocks are still fine — the CAS
// contains many small blobs and occasional large outputs.
local common = import 'common.libsonnet';

{
  grpcServers: [{
    listenAddresses: [':8981'],
    authenticationPolicy: { allow: {} },
  }],
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  global: common.global,
  contentAddressableStorage: {
    backend: {
      'local': {
        keyLocationMapOnBlockDevice: {
          file: {
            path: '/storage-cas/key_location_map',
            sizeBytes: 6 * 1024 * 1024 * 1024,
          },
        },
        keyLocationMapMaximumGetAttempts: 16,
        keyLocationMapMaximumPutAttempts: 64,
        oldBlocks: 8,
        currentBlocks: 24,
        newBlocks: 3,
        blocksOnBlockDevice: {
          source: {
            file: {
              path: '/storage-cas/blocks',
              sizeBytes: 330 * 1024 * 1024 * 1024,
            },
          },
          spareBlocks: 3,
        },
        persistent: {
          stateDirectoryPath: '/storage-cas/persistent_state',
          minimumEpochInterval: '300s',
        },
      },
    },
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
    findMissingAuthorizer: { allow: {} },
  },
  actionCache: {
    backend: {
      'local': {
        keyLocationMapOnBlockDevice: {
          file: {
            path: '/storage-ac/key_location_map',
            sizeBytes: 1 * 1024 * 1024 * 1024,
          },
        },
        keyLocationMapMaximumGetAttempts: 16,
        keyLocationMapMaximumPutAttempts: 64,
        oldBlocks: 8,
        currentBlocks: 24,
        newBlocks: 1,
        blocksOnBlockDevice: {
          source: {
            file: {
              path: '/storage-ac/blocks',
              sizeBytes: 30 * 1024 * 1024 * 1024,
            },
          },
          spareBlocks: 3,
        },
        persistent: {
          stateDirectoryPath: '/storage-ac/persistent_state',
          minimumEpochInterval: '300s',
        },
      },
    },
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
  },
  fileSystemAccessCache: {
    backend: {
      'local': {
        keyLocationMapOnBlockDevice: {
          file: {
            path: '/storage-fsac/key_location_map',
            sizeBytes: 50 * 1024 * 1024,
          },
        },
        keyLocationMapMaximumGetAttempts: 16,
        keyLocationMapMaximumPutAttempts: 64,
        oldBlocks: 8,
        currentBlocks: 24,
        newBlocks: 1,
        blocksOnBlockDevice: {
          source: {
            file: {
              path: '/storage-fsac/blocks',
              sizeBytes: 2 * 1024 * 1024 * 1024,
            },
          },
          spareBlocks: 3,
        },
        persistent: {
          stateDirectoryPath: '/storage-fsac/persistent_state',
          minimumEpochInterval: '300s',
        },
      },
    },
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
  },
}
