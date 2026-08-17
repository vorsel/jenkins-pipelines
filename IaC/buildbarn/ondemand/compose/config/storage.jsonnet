// Storage shard configuration (used by both storage-0 and storage-1 services).
//
// Derived from buildbarn/bb-deployments @ 4da3878, resized for a 1536 GB xfs
// volume (Hetzner volume psmdb-buildbarn-cas-ondemand, ID 105484418). See
// buildbarn-ondemand-scaler.md §5.1 for sizing rationale.
//
// Per-shard budget (two shards total):
//   CAS blocks         : 640 GB  (×2 = 1280 GB on disk)
//   CAS key_location   :  12 GB  (×2 =   24 GB)
//   AC  blocks         :  60 GB  (×2 =  120 GB)
//   AC  key_location   :   2 GB  (×2 =    4 GB)
//   FSAC blocks        :   4 GB  (×2 =    8 GB)
//   FSAC key_location  : 100 MB  (×2 =  200 MB)
//   ────────────────────────────────────────────
//   per shard          : 718 GB
//   both shards        : 1436 GB
//   + xfs + persistent : ~1456 GB  → fits 1536 GB with ~80 GB headroom
//
// Ring buffer layout (oldBlocks + currentBlocks + newBlocks + spareBlocks = 38
// blocks per shard). At 640 GB, block size ≈ 16.8 GB. GC discards ~1/38
// (2.6%) of the CAS at a time — fine for a cache of many small blobs plus
// occasional large outputs.
//
// NOTE: growing a block file's sizeBytes changes the DERIVED block size
// (= sizeBytes / total blocks), so bb-storage's persistent_state can no
// longer reclaim the old blocks (their recorded size no longer matches the
// grid) — this restart therefore RESETS CAS/AC. Accepted deliberately: it's
// a cache, it re-warms over subsequent builds. To grow WITHOUT a reset you
// must keep block size identical by scaling sizeBytes AND all four block
// counts by the same integer factor.
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
            sizeBytes: 12 * 1024 * 1024 * 1024,
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
              sizeBytes: 640 * 1024 * 1024 * 1024,
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
            sizeBytes: 2 * 1024 * 1024 * 1024,
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
              sizeBytes: 60 * 1024 * 1024 * 1024,
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
            sizeBytes: 100 * 1024 * 1024,
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
              sizeBytes: 4 * 1024 * 1024 * 1024,
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
