// Frontend — entry point for Bazel clients (via envoy-proxy on :8981). Fans
// CAS/AC/FSAC calls into the sharded storage tier and forwards Execute calls
// to the scheduler.
//
// Taken verbatim from the working barn-psmdb /root/bb-deployments/docker-compose/
// config/frontend.jsonnet (tag bb-storage:20260326T151518Z-d0c6f26). The only
// thing that changes vs. upstream bb-deployments is the addMetadataJmespath
// expression on the scheduler endpoint — it propagates the Bazel
// RequestMetadata header downstream so bb-browser can link builds back to a
// given Bazel invocation.
local common = import 'common.libsonnet';

{
  grpcServers: [{
    listenAddresses: [':8980'],
    authenticationPolicy: { allow: {} },
  }],
  schedulers: {
    '': {
      endpoint: {
        address: 'scheduler:8982',
        addMetadataJmespathExpression: {
          expression: |||
            {
              "build.bazel.remote.execution.v2.requestmetadata-bin": incomingGRPCMetadata."build.bazel.remote.execution.v2.requestmetadata-bin"
            }
          |||,
        },
      },
    },
  },
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  global: common.global,
  contentAddressableStorage: {
    backend: common.blobstore.contentAddressableStorage,
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
    findMissingAuthorizer: { allow: {} },
  },
  actionCache: {
    backend: common.blobstore.actionCache,
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
  },
  fileSystemAccessCache: {
    backend: common.fileSystemAccessCache,
    getAuthorizer: { allow: {} },
    putAuthorizer: { allow: {} },
  },
  executeAuthorizer: { allow: {} },
}
