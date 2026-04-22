// common.libsonnet for ondemand WORKERS. Distinct from the central's version
// because the worker lives on a separate VM and reaches CAS/AC/FSAC via the
// central's Envoy gateway (bound to 0.0.0.0:8981 on the central host, which
// means it's reachable over the Hetzner private network interface too).
//
// The __CENTRAL_PRIVATE_IP__ and __CENTRAL_PUBLIC_URL__ tokens are substituted
// by scripts/spawn-worker.sh when the cloud-init template is rendered. Never
// commit a file where these are resolved — that would couple a worker config
// to one particular central IP and defeat the point of the template.
// GRPCBlobAccessConfiguration wraps its address in a `client` (a full
// GRPCClientConfiguration) — bare `address` here is the schema mistake that
// caused "unknown field 'address'" on the first spawn. Keep this in sync
// with the barn-psmdb common.libsonnet, where every shard backend uses the
// same `backend: { grpc: { client: { address: '...' } } }` shape.
{
  blobstore: {
    contentAddressableStorage: {
      grpc: { client: { address: '__CENTRAL_PRIVATE_IP__:8981' } },
    },
    actionCache: {
      grpc: { client: { address: '__CENTRAL_PRIVATE_IP__:8981' } },
    },
  },
  fileSystemAccessCache: {
    grpc: { client: { address: '__CENTRAL_PRIVATE_IP__:8981' } },
  },
  // Used by bb-worker when building action-result URLs for the scheduler's
  // admin UI. Uses the central's PUBLIC URL so links work from operator
  // browsers.
  browserUrl: '__CENTRAL_PUBLIC_URL__',
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
