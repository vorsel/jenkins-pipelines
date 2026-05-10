// PSMDB BuildBarn runner image MIRROR — GHCR -> Docker Hub (perconalab).
//
// Why this job exists
// -------------------
// The canonical multi-arch image build now lives in GitHub Actions
// (.github/workflows/build-psmdb-buildbarn-runners.yml) — native amd64 + native
// arm64 runners, no QEMU emulation, ~10x faster than the Jenkins QEMU-based
// sandbox. GHA pushes to GHCR as the system of record:
//
//     ghcr.io/<owner>/psmdb-buildbarn-runners/<distro>:<version>-<sha>  (immutable)
//     ghcr.io/<owner>/psmdb-buildbarn-runners/<distro>:<version>        (moving alias)
//
// PSMDB Bazel pinning lives in bazel/platforms/psmdb_rbe_containers.bzl and is
// pinned at:
//
//     docker.io/perconalab/psmdb-rbe:<distro>-<version>-<sha>           (immutable)
//     docker.io/perconalab/psmdb-rbe:<distro>-<version>                 (moving alias)
//
// This job copies the GHCR multi-arch manifest list to Docker Hub under the
// perconalab single-repo / tag-encoded layout the .bzl points at, without
// re-pulling layers per arch (uses `docker buildx imagetools create` which
// rewires manifest references at the registry level).
//
// Usage
// -----
// Trigger manually from Jenkins UI. Default behavior: mirror all 9 distros
// for all 3 supported PSMDB versions (master, 8.3, 8.0) — i.e. 27 manifest
// lists. Subset via VERSIONS_TO_MIRROR.
//
// Multi-arch is preserved: the GHCR source is already a manifest list (amd64 +
// arm64); imagetools create ports the index unchanged, retagged. No platform
// flag is passed.
//
// The job runs on a docker-x64 agent — no native arm64 capability needed
// because we never execute or unpack the arm64 image, only re-reference it.

library changelog: false, identifier: "lib@hetzner", retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/Percona-Lab/jenkins-pipelines.git'
])

// Distro list = `distro` matrix in build-psmdb-buildbarn-runners.yml. Kept in
// sync manually (the GHA workflow is the source of truth for which distros
// have published images).
def DISTROS = [
    "oraclelinux-8",
    "oraclelinux-9",
    "oraclelinux-10",
    "amazonlinux-2023",
    "ubuntu-jammy",
    "ubuntu-noble",
    "ubuntu-resolute",
    "debian-bookworm",
    "debian-trixie",
]

def ensureDockerBuildx() {
    sh '''
        set -eu
        if docker buildx version >/dev/null 2>&1; then
            echo "docker buildx already present:"
            docker buildx version
            exit 0
        fi
        echo "docker buildx not found — installing modern Docker CE via get.docker.com"
        if [ "$(id -u)" -eq 0 ]; then
            curl -fsSL https://get.docker.com | sh
        else
            curl -fsSL https://get.docker.com | sudo sh
        fi
        docker buildx version
    '''
}

// Returns the 40-hex mongo_sha label embedded in the GHCR image config.
// We pull the linux/amd64 leg of the manifest list (the agent's native arch)
// and read the label out of the image config — same label is stamped on every
// per-arch image during the GHA `build` step, so amd64 is sufficient. Pull is
// cheap relative to imagetools create which then runs server-side anyway.
def resolveMongoSha(String src) {
    return sh(
        script: """
            set -eu
            docker pull --platform linux/amd64 ${src} >/dev/null
            docker inspect --format '{{ index .Config.Labels "org.percona.psmdb.mongo_sha" }}' ${src}
        """,
        returnStdout: true
    ).trim()
}

pipeline {
    agent {
        label 'docker-x64'
    }
    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 60, unit: 'MINUTES')
    }
    parameters {
        string(
            name: 'VERSIONS_TO_MIRROR',
            defaultValue: 'master 8.3 8.0',
            description: 'Space-separated PSMDB version slugs to mirror (any of: master, 8.3, 8.0). Each version pulls the moving tag :<version> for every distro and re-publishes it (plus the immutable :<version>-<sha>) on Docker Hub.'
        )
        string(
            name: 'GHCR_OWNER',
            defaultValue: 'percona-lab',
            description: 'GHCR owner (lower-case). Use `vorsel` to mirror images built from the fork GHA workflow; `percona-lab` is the prod source once images live there.'
        )
        string(
            name: 'GHCR_NAMESPACE',
            defaultValue: 'psmdb-buildbarn-runners',
            description: 'GHCR repo namespace (matches IMAGE_NAMESPACE in build-psmdb-buildbarn-runners.yml).'
        )
        string(
            name: 'DH_CRED_ID',
            defaultValue: 'hub.docker.com',
            description: 'Jenkins credentials id with Docker Hub username/password (write access to docker.io/perconalab/psmdb-rbe).'
        )
        booleanParam(
            name: 'DRY_RUN',
            defaultValue: false,
            description: 'If true, only resolve source images and print the mirror plan; do not push to Docker Hub.'
        )
    }

    environment {
        DH_REGISTRY = 'docker.io'
        DH_REPO     = 'perconalab/psmdb-rbe'
    }

    stages {
        stage('Plan') {
            steps {
                script {
                    def versions = params.VERSIONS_TO_MIRROR.trim().split(/\s+/) as List
                    if (versions.isEmpty() || versions[0] == "") {
                        error "VERSIONS_TO_MIRROR is empty"
                    }
                    env.VERSIONS_LIST = versions.join(' ')
                    echo "===== Mirror plan ====="
                    echo "Versions to mirror : ${env.VERSIONS_LIST}"
                    echo "Distros (all 9)    : ${DISTROS.join(', ')}"
                    echo "Source pattern     : ghcr.io/${params.GHCR_OWNER}/${params.GHCR_NAMESPACE}/<distro>:<version>"
                    echo "Destination repo   : ${env.DH_REGISTRY}/${env.DH_REPO}"
                    echo "Destination tags   : :<distro>-<version>-<sha> (immutable) + :<distro>-<version> (moving)"
                    echo "Dry run            : ${params.DRY_RUN}"
                }
            }
        }

        stage('Mirror') {
            steps {
                script {
                    ensureDockerBuildx()
                    if (!params.DRY_RUN) {
                        withCredentials([usernamePassword(
                            credentialsId: params.DH_CRED_ID,
                            passwordVariable: 'DOCKER_PASS',
                            usernameVariable: 'DOCKER_USER')]) {
                            sh """
                                set -eu
                                echo "\$DOCKER_PASS" | docker login -u "\$DOCKER_USER" --password-stdin ${env.DH_REGISTRY}
                            """
                        }
                    } else {
                        echo "DRY_RUN=true — skipping docker login + push"
                    }

                    def succeeded = []
                    def failed = []

                    DISTROS.each { distro ->
                        env.VERSIONS_LIST.split(/\s+/).each { version ->
                            def src = "ghcr.io/${params.GHCR_OWNER}/${params.GHCR_NAMESPACE}/${distro}:${version}"
                            try {
                                echo "----- ${distro} :: ${version} -----"
                                def mongoSha = resolveMongoSha(src)
                                if (!mongoSha?.matches(/[0-9a-f]{40}/)) {
                                    echo "Source ${src} has no usable org.percona.psmdb.mongo_sha label (got: '${mongoSha}'); skipping"
                                    failed << "${distro}:${version} (no mongo_sha label)"
                                    return
                                }
                                def dhImmutable = "${env.DH_REGISTRY}/${env.DH_REPO}:${distro}-${version}-${mongoSha}"
                                def dhMoving    = "${env.DH_REGISTRY}/${env.DH_REPO}:${distro}-${version}"
                                echo "Source      : ${src}"
                                echo "mongo_sha   : ${mongoSha}"
                                echo "DH immutable: ${dhImmutable}"
                                echo "DH moving   : ${dhMoving}"

                                if (params.DRY_RUN) {
                                    succeeded << "${distro}:${version} -> sha=${mongoSha.substring(0,12)} (dry)"
                                    return
                                }

                                sh """
                                    set -eu
                                    docker buildx imagetools create \\
                                        -t ${dhImmutable} \\
                                        -t ${dhMoving} \\
                                        ${src}
                                    echo "Verifying ${dhImmutable}:"
                                    docker buildx imagetools inspect ${dhImmutable} | head -n 40
                                """
                                succeeded << "${distro}:${version} -> sha=${mongoSha.substring(0,12)}"
                            } catch (Exception ex) {
                                echo "FAILED ${distro}:${version}: ${ex.message}"
                                failed << "${distro}:${version}"
                            }
                        }
                    }

                    echo ""
                    echo "===== Mirror summary ====="
                    echo "Succeeded (${succeeded.size()}):"
                    succeeded.each { echo "  ${it}" }
                    echo "Failed (${failed.size()}):"
                    failed.each { echo "  ${it}" }

                    if (!failed.isEmpty()) {
                        error "Mirror finished with ${failed.size()} failure(s); see log above"
                    }
                }
            }
        }
    }
}
