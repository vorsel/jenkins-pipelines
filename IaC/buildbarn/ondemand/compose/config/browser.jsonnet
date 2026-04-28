// Browser — the BuildBarn web UI. Lets operators inspect CAS blobs, action
// results, and queued/running operations.
//
// Taken verbatim from the working barn-psmdb /root/bb-deployments/docker-compose/
// config/browser.jsonnet (tag bb-browser:20260319T101727Z-1731858). In this
// upstream version the browser stays stateless and only talks to the shared
// blobstore — there is no buildQueueStateProxy / initialSizeClassCache
// configuration (those fields do not exist in the proto schema for this tag).
local common = import 'common.libsonnet';

{
  blobstore: common.blobstore,
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  httpServers: [{
    listenAddresses: [':7984'],
    // TLS termination — cert/key picked up from the volume-mounted
    // /etc/buildbarn/certs/, hot-reloaded every refreshInterval (1h).
    // No auth yet; OIDC via Dex lands in a follow-up step.
    tls: common.serverTls,
    authenticationPolicy: { allow: {} },
  }],
  global: common.global,
  fileSystemAccessCache: common.fileSystemAccessCache,
  authorizer: { allow: {} },
  requestMetadataLinksJmespathExpression: { expression: '`{}`' },
}
