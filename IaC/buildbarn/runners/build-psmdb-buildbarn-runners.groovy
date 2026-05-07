// build-psmdb-buildbarn-runners.groovy — Jenkins-side mirror of
// .github/workflows/build-psmdb-buildbarn-runners.yml.
//
// Why a Jenkins twin of an existing GHA workflow?
//
//   The GHA workflow publishes images to ghcr.io/<owner>/psmdb-buildbarn-runners/<distro>:<tag>,
//   which works while we iterate inside a fork (vorsel/jenkins-pipelines).
//   Upstreaming PSMDB-2034 needs the same images at a registry the official
//   reviewers can pull from without GitHub-Container-Registry credentials.
//   We already have hub.docker.com Jenkins credentials in `hub.docker.com`
//   (see psmdb/psmdb-docker.groovy / psmdb-docker-arm.groovy) and a
//   `perconalab` namespace, so this pipeline pushes the same images to:
//
//     docker.io/perconalab/psmdb-rbe-<distro>:<version>-<sha>          (immutable)
//     docker.io/perconalab/psmdb-rbe-<distro>:<version>                (moving)
//     docker.io/perconalab/psmdb-rbe-<distro>:<version>-<sha>-<arch>   (per-arch leaf)
//
// `<arch>` ∈ {amd64, arm64}; the `<distro>` axis collapses into the repo
// name (Docker Hub does not allow path-segmented repos like ghcr.io does).
// `<version>-<sha>` is identical to the GHA tagging convention so that
// `bazel/platforms/psmdb_rbe_containers.bzl` can flip `container-url`
// from one registry to the other in a single ops bump without changing
// the action-cache shape.
//
// Topology — TWO PARALLEL ARCH LEGS, NOT 36 PARALLEL CELLS:
//
//   Hetzner ARM64 capacity is bursty. Asking for 18 simultaneous
//   docker-aarch64 nodes (one per distro × version cell) routinely
//   stalls in the queue waiting for ARM hosts to spin up. We pin
//   each architecture to a SINGLE node and run all (distro, version)
//   builds for that arch sequentially inside it:
//
//     parallel {
//         amd64 leg → 1× docker-x64,     18 sequential builds
//         arm64 leg → 1× docker-aarch64, 18 sequential builds
//     }
//
//   Wall-clock is dominated by the slower leg (≈ 18 × per-build).
//   Layer-cache reuse inside a single docker daemon also kicks in for
//   the second build of the same base image (e.g. ubuntu-jammy 8.0 →
//   8.3 → master share the apt-cache layers). The cost we trade off
//   is sub-linear; the win is "first ARM node to land does the whole
//   ARM job", which removes the ARM-availability dependency from the
//   pipeline's critical path.
//
//   Pipeline stages:
//     1. `Resolve plan` (docker-x64) — filter (distro × version) from
//        user inputs and resolve mongo_sha ONCE per version (single
//        api.github.com call per version, reused by every distro
//        within that version) so all per-arch builds for the same
//        version land on the same `<sha>` suffix.
//     2. `Build per arch (amd64 ‖ arm64)` — two parallel declarative
//        stages, one bound to docker-x64, one to docker-aarch64.
//        Each stage walks the (distro × version) matrix in a
//        sequential for-loop on its single node.
//     3. `Merge multi-arch manifest list` (docker-x64) — for each
//        (distro, version) pair, stitches the two leaf tags into the
//        `<immutable>` manifest list and (optionally) the `<moving>`
//        moving alias via `docker buildx imagetools create`. This is
//        a registry-side operation, no rebuild.
//
//   Native ARM is preserved by the `docker-aarch64` label (Hetzner
//   ARM64 worker). No QEMU emulation is involved.
//
//   debian-bookworm is multi-arch like the others now that
//   IaC/buildbarn/runners/debian-bookworm-aarch64/Dockerfile exists.

library changelog: false, identifier: "lib@hetzner", retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/Percona-Lab/jenkins-pipelines.git'
])

// One node ⇒ one buildx builder ⇒ shared layer cache across all the
// (distro × version) cells that run on this node. We create the
// builder once at the start of a leg and tear it down in finally.
def runArchLeg(String archShort, String archSuffix, String platform) {
    def distros   = env.SEL_DISTROS.split(/\s+/) as List
    def versions  = env.SEL_VERSIONS.split(/\s+/) as List
    def shaMap    = readJSON(text: env.SHA_MAP_JSON)
    def branchMap = readJSON(text: env.BRANCH_MAP_JSON)

    def builderName = "psmdb-rbe-${env.BUILD_NUMBER}-${archShort}"

    checkout scm

    try {
        withCredentials([usernamePassword(
            credentialsId: env.DH_CRED_ID,
            passwordVariable: 'DOCKER_PASS',
            usernameVariable: 'DOCKER_USER')]) {

            sh """
                set -eu
                echo "\$DOCKER_PASS" | docker login -u "\$DOCKER_USER" --password-stdin ${env.REGISTRY}
                docker buildx create --name '${builderName}' --bootstrap >/dev/null
            """
        }

        if (params.RUN_TRIVY) {
            installTrivy(method: 'binary', junitTpl: true)
        }

        for (d in distros) {
            for (v in versions) {
                def imageBase      = "${env.IMAGE_NAMESPACE}/${env.IMAGE_PREFIX}${d}"
                def perArchTag     = "${v}-${shaMap[v]}-${archShort}"
                def fullPerArchRef = "${env.REGISTRY}/${imageBase}:${perArchTag}"
                def branch         = branchMap[v]
                def sha            = shaMap[v]

                stage("${archShort}: ${d}-${v}") {
                    withCredentials([usernamePassword(
                        credentialsId: env.DH_CRED_ID,
                        passwordVariable: 'DOCKER_PASS',
                        usernameVariable: 'DOCKER_USER')]) {

                        sh """
                            set -eu
                            # Re-login per cell — DH session can age out across
                            # a long sequential leg (20+ minutes per cell × 18
                            # cells). Cheap, idempotent.
                            echo "\$DOCKER_PASS" | docker login -u "\$DOCKER_USER" --password-stdin ${env.REGISTRY}

                            docker buildx build \\
                                --builder '${builderName}' \\
                                --platform ${platform} \\
                                --provenance=false --sbom=false \\
                                --build-arg MONGO_REPO='${params.MONGO_REPO}' \\
                                --build-arg MONGO_BRANCH='${branch}' \\
                                --build-arg PSMDB_VERSION='${v}' \\
                                --build-arg CACHE_BUST="\$(date +%s)" \\
                                --label org.opencontainers.image.source="${env.GIT_URL ?: ''}" \\
                                --label org.opencontainers.image.revision="${env.GIT_COMMIT ?: ''}" \\
                                --label org.percona.psmdb.version='${v}' \\
                                --label org.percona.psmdb.mongo_repo='${params.MONGO_REPO}' \\
                                --label org.percona.psmdb.mongo_branch='${branch}' \\
                                --label org.percona.psmdb.mongo_sha='${sha}' \\
                                -t '${fullPerArchRef}' \\
                                --push \\
                                -f IaC/buildbarn/runners/${d}-${archSuffix}/Dockerfile \\
                                IaC/buildbarn/runners/${d}-${archSuffix}
                        """
                    }

                    if (params.RUN_TRIVY) {
                        sh """
                            set -eu
                            curl -fsSL https://raw.githubusercontent.com/Percona-QA/psmdb-testing/main/docker/trivyignore -o .trivyignore || true
                            # --exit-code 0: never fail the cell on findings; the JUnit
                            # report surfaces them in Jenkins for triage. Tighten to 1
                            # only after we have a sustained zero-finding baseline.
                            /usr/local/bin/trivy -q image \\
                                --format template --template @junit.tpl \\
                                -o trivy-${d}-${v}-${archShort}-junit.xml \\
                                --timeout 10m0s --ignore-unfixed --exit-code 0 \\
                                --severity HIGH,CRITICAL \\
                                '${fullPerArchRef}'
                        """
                        junit testResults: "trivy-${d}-${v}-${archShort}-junit.xml",
                              allowEmptyResults: true,
                              skipPublishingChecks: true
                    }
                }
            }
        }
    } finally {
        sh """
            docker buildx rm '${builderName}' 2>/dev/null || true
            docker logout ${env.REGISTRY} 2>/dev/null || true
            docker image prune -f >/dev/null 2>&1 || true
        """
        deleteDir()
    }
}

pipeline {
    agent none

    triggers {
        // Weekly rebuild to pick up CVE updates in base images and any
        // drift in psmdb_builder_<version>.sh install_deps() — Mondays
        // 03:00 server time, mirroring the GHA cron.
        cron('0 3 * * 1')
    }

    parameters {
        string(
            name: 'PSMDB_VERSIONS_FILTER',
            defaultValue: '',
            description: 'Subset of PSMDB release lines to build (space-separated: 8.0 8.3 master; empty = all)'
        )
        string(
            name: 'DISTROS_FILTER',
            defaultValue: '',
            description: 'Subset of distros to build (space-separated; empty = all). Allowed: oraclelinux-8 oraclelinux-9 amazonlinux-2023 ubuntu-jammy ubuntu-noble debian-bookworm'
        )
        booleanParam(
            name: 'PUSH_MOVING',
            defaultValue: true,
            description: 'Also push the :<version> moving tag (disable for isolated branch experiments that must not overwrite the current pointer)'
        )
        string(
            name: 'MONGO_REPO',
            defaultValue: 'https://github.com/vorsel/percona-server-mongodb.git',
            description: 'mongo repo URL (clone source for psmdb_builder.sh; switch to upstream once the PR lands there)'
        )
        string(
            name: 'MONGO_BRANCH_V80',
            defaultValue: '',
            description: 'Override mongo branch for psmdb_version=8.0 (default: v8.0)'
        )
        string(
            name: 'MONGO_BRANCH_V83',
            defaultValue: '',
            description: 'Override mongo branch for psmdb_version=8.3 (default: v8.3)'
        )
        string(
            name: 'MONGO_BRANCH_MASTER',
            defaultValue: '',
            description: 'Override mongo branch for psmdb_version=master (default: master)'
        )
        booleanParam(
            name: 'RUN_TRIVY',
            defaultValue: true,
            description: 'Run a Trivy CVE scan (HIGH+CRITICAL, --ignore-unfixed) on each per-arch image after build'
        )
    }

    options {
        // 18 sequential cells per arch leg × ~15 min/cell + Hetzner
        // queue + merge ≈ up to 6 h. Pad slightly for first-time
        // base-image pulls.
        timeout(time: 8, unit: 'HOURS')
        timestamps()
        // No two simultaneous workflow_dispatch + cron firings for the
        // same job — manifest list creation is not idempotent under race.
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '5'))
    }

    environment {
        REGISTRY        = 'docker.io'
        IMAGE_NAMESPACE = 'perconalab'
        IMAGE_PREFIX    = 'psmdb-rbe-'
        DH_CRED_ID      = 'hub.docker.com'
    }

    stages {
        stage('Resolve plan') {
            agent { label 'docker-x64' }
            steps {
                script {
                    def allDistros  = ['oraclelinux-8','oraclelinux-9','amazonlinux-2023',
                                       'ubuntu-jammy','ubuntu-noble','debian-bookworm']
                    def allVersions = ['8.0','8.3','master']

                    def selDistros = params.DISTROS_FILTER?.trim() ?
                        params.DISTROS_FILTER.trim().split(/\s+/) as List : allDistros
                    def selVersions = params.PSMDB_VERSIONS_FILTER?.trim() ?
                        params.PSMDB_VERSIONS_FILTER.trim().split(/\s+/) as List : allVersions

                    selDistros.removeAll  { !(it in allDistros) }
                    selVersions.removeAll { !(it in allVersions) }
                    if (selDistros.isEmpty() || selVersions.isEmpty()) {
                        error "Empty matrix after filtering: distros=${selDistros}, versions=${selVersions}"
                    }

                    def repoUrl = params.MONGO_REPO
                    def matcher = (repoUrl =~ /github\.com[:\/]([^\/]+\/[^\/]+?)(?:\.git)?$/)
                    if (!matcher.find()) {
                        error "Cannot parse mongo repo URL: ${repoUrl}"
                    }
                    def ownerRepo = matcher.group(1)

                    // Resolve mongo_sha ONCE per version. The path filter is
                    // psmdb_builder.sh, which is repo-wide — distro doesn't
                    // change the answer.
                    def shaMap    = [:]
                    def branchMap = [:]
                    for (v in selVersions) {
                        def defBranch = (v == '8.0') ? 'v8.0' :
                                        (v == '8.3') ? 'v8.3' : 'master'
                        def overrideBranch = (v == '8.0')    ? params.MONGO_BRANCH_V80 :
                                             (v == '8.3')    ? params.MONGO_BRANCH_V83 :
                                                               params.MONGO_BRANCH_MASTER
                        def branch = overrideBranch?.trim() ? overrideBranch.trim() : defBranch
                        branchMap[v] = branch

                        def sha = sh(returnStdout: true, script: """
                            set -eu
                            curl -fsSL --retry 3 --retry-delay 2 \
                                -H 'Accept: application/vnd.github+json' \
                                'https://api.github.com/repos/${ownerRepo}/commits?path=percona-packaging/scripts/psmdb_builder.sh&sha=${branch}&per_page=1' \
                                | jq -r '.[0].sha'
                        """).trim()
                        if (!sha || sha == 'null' || sha == '') {
                            error "Failed to resolve mongo_sha for ${ownerRepo}@${branch} (psmdb_version=${v})"
                        }
                        shaMap[v] = sha
                        echo "Resolved psmdb_version=${v} mongo_branch=${branch} mongo_sha=${sha}"
                    }

                    env.SEL_DISTROS     = selDistros.join(' ')
                    env.SEL_VERSIONS    = selVersions.join(' ')
                    env.SHA_MAP_JSON    = writeJSON(json: shaMap, returnText: true)
                    env.BRANCH_MAP_JSON = writeJSON(json: branchMap, returnText: true)

                    def total = selDistros.size() * selVersions.size()
                    currentBuild.displayName =
                        "v=${selVersions.join(',')} d=${selDistros.size()} t=${total * 2}cells"
                    echo "Matrix: ${selDistros.size()} distros × ${selVersions.size()} versions × 2 archs = ${total * 2} build cells (${total} per leg, sequential)"
                }
            }
        }

        stage('Build per arch (amd64 ‖ arm64)') {
            parallel {
                stage('amd64 leg (docker-x64)') {
                    agent { label 'docker-x64' }
                    steps {
                        script {
                            runArchLeg('amd64', 'x86_64', 'linux/amd64')
                        }
                    }
                }
                stage('arm64 leg (docker-aarch64)') {
                    agent { label 'docker-aarch64' }
                    steps {
                        script {
                            runArchLeg('arm64', 'aarch64', 'linux/arm64')
                        }
                    }
                }
            }
        }

        stage('Merge multi-arch manifest list per (distro, version)') {
            agent { label 'docker-x64' }
            steps {
                script {
                    def distros  = env.SEL_DISTROS.split(/\s+/) as List
                    def versions = env.SEL_VERSIONS.split(/\s+/) as List
                    def shaMap   = readJSON(text: env.SHA_MAP_JSON)

                    withCredentials([usernamePassword(
                        credentialsId: env.DH_CRED_ID,
                        passwordVariable: 'DOCKER_PASS',
                        usernameVariable: 'DOCKER_USER')]) {

                        sh """
                            set -eu
                            echo "\$DOCKER_PASS" | docker login -u "\$DOCKER_USER" --password-stdin ${env.REGISTRY}
                        """

                        for (d in distros) {
                            for (v in versions) {
                                def imageBase     = "${env.IMAGE_NAMESPACE}/${env.IMAGE_PREFIX}${d}"
                                def sha           = shaMap[v]
                                def immutableTag  = "${v}-${sha}"
                                def fullImmutable = "${env.REGISTRY}/${imageBase}:${immutableTag}"
                                def amd64Ref      = "${env.REGISTRY}/${imageBase}:${immutableTag}-amd64"
                                def arm64Ref      = "${env.REGISTRY}/${imageBase}:${immutableTag}-arm64"

                                def tagArgs = "-t '${fullImmutable}'"
                                if (params.PUSH_MOVING) {
                                    def fullMoving = "${env.REGISTRY}/${imageBase}:${v}"
                                    tagArgs += " -t '${fullMoving}'"
                                }

                                sh """
                                    set -eu
                                    docker buildx imagetools create ${tagArgs} '${amd64Ref}' '${arm64Ref}'
                                    docker buildx imagetools inspect '${fullImmutable}'
                                """

                                def archs = sh(returnStdout: true, script: """
                                    docker buildx imagetools inspect '${fullImmutable}' \
                                        | awk '/^[[:space:]]*Platform:/ {print \$2}' \
                                        | sort -u | paste -sd ', ' -
                                """).trim()

                                echo "Pushed ${fullImmutable} (archs: ${archs})"
                                if (params.PUSH_MOVING) {
                                    echo "Moving alias also pushed: ${env.REGISTRY}/${imageBase}:${v}"
                                }
                            }
                        }
                    }
                }
            }
            post {
                always {
                    sh """
                        docker logout ${env.REGISTRY} 2>/dev/null || true
                        docker image prune -f >/dev/null 2>&1 || true
                    """
                    deleteDir()
                }
            }
        }
    }

    post {
        success {
            slackNotify(
                "#mongodb_autofeed",
                "#00FF00",
                "[${env.JOB_NAME}]: PSMDB BuildBarn runners build succeeded — ${currentBuild.displayName} — ${env.BUILD_URL}"
            )
        }
        unstable {
            slackNotify(
                "#mongodb_autofeed",
                "#F6F930",
                "[${env.JOB_NAME}]: PSMDB BuildBarn runners build UNSTABLE — ${currentBuild.displayName} — ${env.BUILD_URL}testReport/"
            )
        }
        failure {
            slackNotify(
                "#mongodb_autofeed",
                "#FF0000",
                "[${env.JOB_NAME}]: PSMDB BuildBarn runners build FAILED — ${currentBuild.displayName} — ${env.BUILD_URL}"
            )
        }
    }
}
