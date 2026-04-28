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
    tls: common.serverTls,
    // OIDC delegation to Dex. Anonymous requests get a 302 to Dex /auth
    // → GitHub OAuth → Dex /callback (where team membership is checked)
    // → /oidc-callback here (BB exchanges code for token, drops a
    // session cookie). See common.libsonnet :: oidcAuth for the full
    // flow walk-through and the precise reasons each field is shaped
    // the way it is.
    //
    // CLIENT IDENTITY: 'bb-browser' is the Dex staticClient ID declared
    // in compose/dex/dex.yaml; the secret on the next line is the
    // matching staticClient secret. Both placeholders are sed-replaced
    // by create-central.sh's bake_env step from .env (mode 0600,
    // generated once with `openssl rand -hex 32` and preserved across
    // re-runs to avoid invalidating live sessions).
    //
    // CALLBACK: /oidc-callback is registered in dex.yaml's staticClients
    // [bb-browser].redirectURIs. Path chosen to NOT overlap with any
    // valid bb-browser route (CAS blob views, action explorers, etc.
    // all live under /<digest>/… or /operations/…).
    authenticationPolicy: common.oidcAuth(
      clientId='bb-browser',
      clientSecret='__BB_BROWSER_OIDC_CLIENT_SECRET__',
      redirectUrl=common.browserUrl + '/oidc-callback',
      cookieSeed='__BB_BROWSER_COOKIE_SEED__',
    ),
  }],
  global: common.global,
  fileSystemAccessCache: common.fileSystemAccessCache,
  authorizer: { allow: {} },
  requestMetadataLinksJmespathExpression: { expression: '`{}`' },
}
