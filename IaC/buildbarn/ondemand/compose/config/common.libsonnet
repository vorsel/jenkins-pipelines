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
  // Public URL of the scheduler admin UI — used by oidcAuth() below to
  // build the per-service OAuth2 redirect_uri. Different port from
  // browserUrl on purpose (scheduler admin is on :7982). sed-replaced
  // by create-central.sh's bake_env step with `https://$PUBLIC_HOSTNAME:7982`.
  schedulerUrl: '__BB_SCHEDULER_URL__',
  // Public URL of bb-portal — build observability UI on :7986. Same
  // shape and substitution rules as browserUrl / schedulerUrl above;
  // sed-replaced by create-central.sh's bake_env step with
  // `https://$PUBLIC_HOSTNAME:7986`. Used by bb-portal.jsonnet to
  // build the OAuth2 redirect_uri (`portalUrl + '/oidc-callback'`)
  // and the CORS allow-list (`allowedOrigins: [portalUrl]`).
  portalUrl: '__BB_PORTAL_URL__',
  // Dex OIDC issuer URL — `https://$PUBLIC_HOSTNAME:5556`. Used both as
  // the prefix for /auth and /token endpoints AND as what Buildbarn
  // expects to see in id_token's `iss` claim. Must EXACTLY match the
  // `issuer:` field in compose/dex/dex.yaml or token validation fails
  // silently (the OIDC library compares strings byte-for-byte).
  // sed-replaced by bake_env.
  oidcIssuer: '__BB_OIDC_ISSUER__',
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

  // TLS for public HTTP servers (bb-browser :7984, bb-scheduler admin :7982).
  // The cert files are kept in /var/lib/buildbarn/certs on the host and
  // mounted read-only into each container at /etc/buildbarn/certs by
  // docker-compose.yml. The certbot deploy-hook (10-buildbarn.sh) re-copies
  // both files in place after each renewal; refreshInterval picks them up
  // without restarting the BB process. See buildbarn-auth-tls-plan.md §4.
  serverTls: {
    serverKeyPair: {
      files: {
        certificatePath: '/etc/buildbarn/certs/fullchain.pem',
        privateKeyPath: '/etc/buildbarn/certs/privkey.pem',
        refreshInterval: '3600s',
      },
    },
  },

  // OIDC authentication policy builder for bb-browser and bb-scheduler
  // (admin UI). Returns a value suitable for the `authenticationPolicy`
  // field of an HttpServers entry in either jsonnet config.
  //
  // Maps to bb-storage's OIDCAuthenticationPolicy (proto in
  // bb-storage/pkg/proto/configuration/http/server/server.proto), which
  // implements the OAuth2 authorization-code flow with the following
  // server-side wiring (verified against bb-storage HEAD as of
  // 2026-04-28, see pkg/http/server/authenticator.go and
  // oidc_authenticator.go):
  //
  //   1. Anonymous request → BB writes a state cookie and 302-redirects
  //      the user's browser to authorizationEndpointUrl + ?client_id=
  //      &redirect_uri=&response_type=code&scope=…&state=…
  //   2. Dex's GitHub connector enforces orgs[].teams[] membership at
  //      /callback (returns "User not in any of the required orgs/teams"
  //      for non-members). Successful logins land back on Dex /callback,
  //      which 302s the browser to redirectUrl with ?code=…&state=…
  //   3. BB at redirectUrl handler verifies state cookie, exchanges
  //      `code` for a token at tokenEndpointUrl over TLS, and trusts
  //      the id_token field in the response BECAUSE THE EXCHANGE WAS
  //      OVER TLS TO A KNOWN-GOOD URL (BB does NOT verify id_token
  //      signatures — see oidc_authenticator.go::idTokenOIDCClaimsFetcher
  //      which just base64-decodes the JWT payload).
  //   4. id_token claims are run through metadataExtractionJmespath
  //      Expression to populate AuthenticationMetadata.public, and
  //      stored in an AES-GCM-encrypted session cookie keyed off
  //      cookieSeed + the rest of the OIDC config (changing any of
  //      these invalidates all live sessions on next deploy — by
  //      design).
  //
  // Note that authorization gating (team-membership enforcement) lives
  // ENTIRELY in Dex's GitHub connector (see compose/dex/dex.yaml's
  // `orgs[].teams[]`). This builder only authenticates: any user who
  // makes it through Dex's gate gets a session here. There is no second
  // authorization layer because BB's HTTP server proto has no
  // authorizer field — see server.proto:HttpServerConfiguration. If we
  // ever need a second gate (e.g. role-based UI features), it'd have to
  // be added in BB upstream first.
  //
  // Args:
  //   clientId       — must match dex.yaml staticClients[].id
  //   clientSecret   — must match dex.yaml staticClients[].secret;
  //                    the value here is sed-substituted from
  //                    BB_*_OIDC_SECRET in .env at bake time
  //   redirectUrl    — full https URL of the OAuth2 callback handler
  //                    on this very service. Must (a) match a
  //                    redirectURIs entry in dex.yaml staticClients,
  //                    (b) not collide with any other valid path BB
  //                    serves on this listener (proto comment).
  //                    `/oidc-callback` is reserved across both UIs.
  //   cookieSeed     — extra entropy mixed into the session-cookie
  //                    AES key derivation; sed-substituted from
  //                    BB_*_COOKIE_SEED in .env. Rotation of this
  //                    seed forces a re-login on next request.
  oidcAuth(clientId, clientSecret, redirectUrl, cookieSeed):: {
    oidc: {
      clientId: clientId,
      clientSecret: clientSecret,
      // /auth and /token both live under the same Dex listener.
      // Browser-facing /auth is hit by the user's external browser
      // (resolves bb.psmdb.percona.com via public DNS → floating IP →
      // host:5556 → dex container).
      // Server-facing /token is hit by BB's internal HTTP client
      // (resolves bb.psmdb.percona.com via docker DNS — the dex
      // service has a network alias for this hostname in
      // docker-compose.yml — so the call stays on the docker bridge
      // and never leaves the host). The TLS handshake validates the
      // SAN against the hostname in the URL, NOT against the dest
      // IP, so cert validation passes either way.
      authorizationEndpointUrl: $.oidcIssuer + '/auth',
      tokenEndpointUrl: $.oidcIssuer + '/token',
      // Pull claims (incl. `groups`) from the id_token rather than
      // calling /userinfo separately. Saves a round-trip and avoids
      // the `userinfo` endpoint whose response shape is
      // connector-specific in Dex (some claims like `groups` only
      // appear in id_token by default).
      useIdTokenClaims: {},
      redirectUrl: redirectUrl,
      // `groups` is REQUIRED to make Dex include the team-membership
      // claim in id_token (see Dex docs: "If the requested scopes
      // include groups…"). `offline_access` requests a refresh token
      // so BB can keep the session alive without re-bouncing through
      // GitHub on every id_token expiry (1 h per dex.yaml).
      scopes: ['openid', 'email', 'profile', 'groups', 'offline_access'],
      cookieSeed: cookieSeed,
      // Empty {} = use Go's default HTTP transport (system root CAs
      // — Let's Encrypt's chain is trusted out of the box on Debian
      // 13 and on the bb-* upstream Alpine images). If we ever pin
      // a custom CA bundle, it goes here as `tls: { caCertificates: …}`.
      httpClient: {},
      // Shape the id_token claims into AuthenticationMetadata.public.
      // `public` is what bb-browser displays in its UI as "logged in
      // as <username>", so we surface preferred_username / email /
      // groups for human visibility and audit. We deliberately don't
      // populate `private` — there's no downstream authorizer that
      // would consume it (see comment above).
      metadataExtractionJmespathExpression: {
        expression: '{"public": {"username": preferred_username, "email": email, "groups": groups}}',
      },
    },
  },
}
