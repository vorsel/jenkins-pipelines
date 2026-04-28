// common.libsonnet for ondemand WORKERS. Distinct from the central's version
// because the worker lives on a separate VM and reaches CAS/AC/FSAC over the
// Hetzner private network — directly to bb-frontend's plaintext gRPC on
// __CENTRAL_PRIVATE_IP__:8980, NOT via the public Envoy gateway on :8981.
//
// Why bypass Envoy:
//   Step 5 of buildbarn-auth-tls-plan.md added TLS termination + a
//   jwt_authn filter to the public Envoy listener on :8981 so that Bazel
//   clients out on the Internet must present a Dex-issued OIDC bearer
//   token. Workers don't have (and shouldn't need) such a token: they
//   live inside our Hetzner private network, which already gates access
//   at the perimeter. Trying to route them through Envoy would force us
//   to (a) provision long-lived service-account JWTs to every spawned
//   VM and (b) carry the TLS handshake cost on every CAS read/write.
//   Cheaper and architecturally cleaner: workers stay on the trusted
//   private hop straight into bb-frontend's :8980 listener (which has
//   `authenticationPolicy: { allow: {} }` because the network IS the
//   auth boundary on this path).
//
//   For the wire to work, compose/docker-compose.yml must publish the
//   frontend's :8980 on ${PRIVATE_IP}:8980 (mirror of what scheduler does
//   on :8983). If you ever see workers EOF'ing CAS reads with
//   "error reading server preface: unexpected EOF" or "Failed to obtain
//   input directory", check that the host port mapping is still in place
//   AND that the Hetzner network firewall (if any) still admits intra-
//   network traffic on :8980.
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
      grpc: { client: { address: '__CENTRAL_PRIVATE_IP__:8980' } },
    },
    actionCache: {
      grpc: { client: { address: '__CENTRAL_PRIVATE_IP__:8980' } },
    },
  },
  fileSystemAccessCache: {
    grpc: { client: { address: '__CENTRAL_PRIVATE_IP__:8980' } },
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
