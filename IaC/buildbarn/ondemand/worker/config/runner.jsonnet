// bb_runner configuration — this is what runs INSIDE the pool-specific
// runner container (ghcr.io/vorsel/psmdb-buildbarn-runners/*). The bb_runner
// binary itself is shipped via the bb-runner-installer container into a
// shared /bb volume; the runner container waits for /bb/installed, then
// execs /bb/bb_runner against this config.
//
// Taken verbatim from barn-psmdb /root/bb-deployments/docker-compose/config/
// runner-ubuntu22-04.jsonnet — the runner side of the loop hasn't changed
// between prod and ondemand.
local common = import 'common.libsonnet';

{
  buildDirectoryPath: '/worker/build',
  global: common.global,
  grpcServers: [{
    listenPaths: ['/worker/runner'],
    authenticationPolicy: { allow: {} },
  }],
}
