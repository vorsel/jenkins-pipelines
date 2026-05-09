// PSMDB BuildBarn runner image SANDBOX — parameterized one-off image build.
//
// Companion to the canonical matrix job `hetzner-psmdb-buildbarn-runners`,
// trimmed to a single (distro × version) cell driven by job parameters.
// The use case this exists for: smoke-testing a brand-new distro before it
// has a checked-in Dockerfile in IaC/buildbarn/runners/<distro-arch>/. The
// caller supplies BASE_IMAGE (e.g. `ubuntu:26.04`) and PKG_MANAGER (apt|dnf)
// and the job synthesizes a minimal Dockerfile on the fly that mirrors the
// canonical pattern (FROM <base> → install bash/ca-certificates/wget/curl
// → wget psmdb_builder.sh from the requested PSMDB branch → run
// `--install_deps=1`). No Dockerfile commit is needed in this repo.
//
// Multi-arch build is done by `docker buildx build --platform
// linux/amd64,linux/arm64 --push` on a single docker-x64 agent — QEMU
// emulates the arm64 layer. Slower than the canonical job's two-leg
// native topology but acceptable for one-off sandbox builds.
//
// Output: two tags pushed to Docker Hub
//   docker.io/perconalab/psmdb-rbe:<distro_label>-<psmdb_version>-<sha>  (immutable)
//   docker.io/perconalab/psmdb-rbe:<distro_label>-<psmdb_version>        (moving alias)
//
// Once the smoke build is green, the operator promotes the distro by
// adding a real Dockerfile under IaC/buildbarn/runners/<distro_label>-<arch>/
// and the matching pool entries to ondemand-pools.yaml + the .bzl row in
// the percona-server-mongodb fork.

library changelog: false, identifier: "lib@hetzner", retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/Percona-Lab/jenkins-pipelines.git'
])

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

// Renders a minimal runner Dockerfile inline. Differs from the per-distro
// checked-in Dockerfiles only in the FROM line and the package-manager
// boot RUN — the install_deps stage is identical.
def renderDockerfile(String baseImage, String pkgMgr, String distroLabel, String arch) {
    def installLine
    def cleanupTail
    if (pkgMgr == 'apt') {
        installLine = '''ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC
RUN apt-get update && apt-get install -y --no-install-recommends \\
        bash \\
        ca-certificates \\
        curl \\
        wget \\
    && rm -rf /var/lib/apt/lists/*'''
        cleanupTail = '/var/lib/apt/lists/*'
    } else {
        installLine = '''ENV LANG=C.UTF-8
ENV TZ=Etc/UTC
RUN dnf install -y --setopt=install_weak_deps=False \\
        bash \\
        ca-certificates \\
        wget \\
    && dnf clean all \\
    && rm -rf /var/cache/dnf'''
        cleanupTail = '/var/cache/dnf'
    }

    return """\
# PSMDB BuildBarn runner image — synthesized by build-psmdb-buildbarn-runner-sandbox
# distro_label = ${distroLabel}
# arch         = ${arch}
# base_image   = ${baseImage}
# pkg_manager  = ${pkgMgr}

FROM ${baseImage}

${installLine}

ARG MONGO_REPO=https://github.com/vorsel/percona-server-mongodb.git
ARG MONGO_BRANCH=master
ARG PSMDB_VERSION

ARG CACHE_BUST=0
RUN mkdir -p /tmp/build \\
 && RAW_URL="\$(echo \${MONGO_REPO} | sed -re 's|github.com|raw.githubusercontent.com|; s|\\.git\$||')/\${MONGO_BRANCH}/percona-packaging/scripts/psmdb_builder.sh" \\
 && echo "CACHE_BUST=\${CACHE_BUST} fetching \${RAW_URL}" \\
 && wget -q "\${RAW_URL}" -O /tmp/psmdb_builder.sh \\
 && chmod +x /tmp/psmdb_builder.sh \\
 && bash -x /tmp/psmdb_builder.sh --builddir=/tmp/build --install_deps=1 \\
 && rm -rf /tmp/psmdb_builder.sh /tmp/build /root/.cache ${cleanupTail}

LABEL org.opencontainers.image.title="psmdb-runner-${distroLabel}-${arch}"
LABEL org.opencontainers.image.description="BuildBarn runner (sandbox build) on ${baseImage}"
LABEL org.percona.psmdb.os="${distroLabel}"
LABEL org.percona.psmdb.arch="${arch}"
LABEL org.percona.psmdb.version=\$PSMDB_VERSION
LABEL org.percona.psmdb.sandbox="true"
LABEL org.percona.psmdb.builder_script="percona-packaging/scripts/psmdb_builder.sh install_deps()"
"""
}

// Uses the `sh` Pipeline step (sandbox-safe) instead of List.execute(),
// which is rejected by Jenkins script-security on this master.
def resolveBranchSha(String repoUrl, String branch) {
    def out = sh(
        script: "git ls-remote ${repoUrl} refs/heads/${branch}",
        returnStdout: true
    ).trim()
    if (!out) {
        error "Branch '${branch}' not found on ${repoUrl}"
    }
    // git ls-remote prints "<sha>\trefs/heads/<branch>" — pluck the SHA.
    return out.split('\n')[0].split(/\s+/)[0]
}

pipeline {
    agent {
        label 'docker-x64'
    }
    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 90, unit: 'MINUTES')
    }
    parameters {
        string(
            name: 'MONGO_REPO',
            defaultValue: 'https://github.com/vorsel/percona-server-mongodb.git',
            description: 'PSMDB git repo URL — psmdb_builder.sh source'
        )
        string(
            name: 'MONGO_BRANCH',
            defaultValue: 'master',
            description: 'Branch on MONGO_REPO that holds the psmdb_builder.sh to bake'
        )
        string(
            name: 'DISTRO_LABEL',
            defaultValue: 'ubuntu-resolute',
            description: 'Distro slug used in the image tag (e.g. ubuntu-resolute, debian-trixie, oraclelinux-10)'
        )
        string(
            name: 'BASE_IMAGE',
            defaultValue: 'ubuntu:26.04',
            description: 'Docker base image to FROM (e.g. ubuntu:26.04, debian:trixie, oraclelinux:10)'
        )
        choice(
            name: 'PKG_MANAGER',
            choices: ['apt', 'dnf'],
            description: 'Native package manager of the base distro (apt for Debian/Ubuntu, dnf for RHEL/OL)'
        )
        string(
            name: 'PSMDB_VERSION',
            defaultValue: 'master',
            description: 'PSMDB version slug used in the tag suffix (master|8.0|8.3)'
        )
        string(
            name: 'ARCHS',
            defaultValue: 'linux/amd64,linux/arm64',
            description: 'docker buildx --platform value (comma-separated)'
        )
        booleanParam(
            name: 'PUSH_TO_DOCKER_HUB',
            defaultValue: true,
            description: 'Push the image to docker.io/perconalab/psmdb-rbe. Uncheck for local-only smoke build.'
        )
        string(
            name: 'DH_CRED_ID',
            defaultValue: 'hub.docker.com',
            description: 'Jenkins credentials id with Docker Hub username/password'
        )
    }

    environment {
        REGISTRY        = 'docker.io'
        IMAGE_NAMESPACE = 'perconalab'
        IMAGE_NAME      = 'psmdb-rbe'
    }

    stages {
        stage('Resolve plan') {
            steps {
                script {
                    def sha = resolveBranchSha(params.MONGO_REPO, params.MONGO_BRANCH)
                    if (!sha?.matches(/[0-9a-f]{40}/)) {
                        error "Resolved SHA does not look like a 40-hex string: '${sha}'"
                    }
                    env.MONGO_SHA   = sha
                    env.MONGO_SHA12 = sha.substring(0, 12)

                    def imageBase  = "${env.IMAGE_NAMESPACE}/${env.IMAGE_NAME}"
                    def immutable  = "${params.DISTRO_LABEL}-${params.PSMDB_VERSION}-${env.MONGO_SHA}"
                    def alias      = "${params.DISTRO_LABEL}-${params.PSMDB_VERSION}"
                    env.FULL_IMMUTABLE_REF = "${env.REGISTRY}/${imageBase}:${immutable}"
                    env.FULL_ALIAS_REF     = "${env.REGISTRY}/${imageBase}:${alias}"

                    echo "===== Sandbox build plan ====="
                    echo "MONGO_REPO        : ${params.MONGO_REPO}"
                    echo "MONGO_BRANCH      : ${params.MONGO_BRANCH}"
                    echo "MONGO_SHA         : ${env.MONGO_SHA}"
                    echo "DISTRO_LABEL      : ${params.DISTRO_LABEL}"
                    echo "BASE_IMAGE        : ${params.BASE_IMAGE}"
                    echo "PKG_MANAGER       : ${params.PKG_MANAGER}"
                    echo "ARCHS             : ${params.ARCHS}"
                    echo "PSMDB_VERSION     : ${params.PSMDB_VERSION}"
                    echo "Immutable target  : ${env.FULL_IMMUTABLE_REF}"
                    echo "Moving alias      : ${env.FULL_ALIAS_REF}"
                    echo "Push to DH        : ${params.PUSH_TO_DOCKER_HUB}"
                }
            }
        }

        stage('Render Dockerfile') {
            steps {
                script {
                    def archShort = params.ARCHS.contains(',') ? 'multi' : params.ARCHS.replaceAll(/.*\//, '')
                    def df = renderDockerfile(
                        params.BASE_IMAGE,
                        params.PKG_MANAGER,
                        params.DISTRO_LABEL,
                        archShort
                    )
                    sh "mkdir -p sandbox-build && rm -f sandbox-build/Dockerfile"
                    writeFile file: 'sandbox-build/Dockerfile', text: df, encoding: 'UTF-8'
                    sh '''
                        set -eu
                        echo "===== Synthesized Dockerfile ====="
                        cat sandbox-build/Dockerfile
                        echo "===== /Dockerfile ====="
                    '''
                }
            }
        }

        stage('Build + push') {
            steps {
                script {
                    ensureDockerBuildx()
                    def builderName = "psmdb-sandbox-${env.BUILD_NUMBER}"
                    try {
                        withCredentials([usernamePassword(
                            credentialsId: params.DH_CRED_ID,
                            passwordVariable: 'DOCKER_PASS',
                            usernameVariable: 'DOCKER_USER')]) {
                            sh """
                                set -eu
                                echo "\$DOCKER_PASS" | docker login -u "\$DOCKER_USER" --password-stdin ${env.REGISTRY}
                                docker buildx create --name '${builderName}' --bootstrap >/dev/null
                                docker buildx use '${builderName}'
                            """
                        }

                        def pushFlag = params.PUSH_TO_DOCKER_HUB ? '--push' : '--load'
                        // --load works only for single-arch builds; in multi-arch we must --push.
                        if (!params.PUSH_TO_DOCKER_HUB && params.ARCHS.contains(',')) {
                            error "PUSH_TO_DOCKER_HUB=false is incompatible with multi-arch ARCHS=${params.ARCHS}; pick a single platform or enable push."
                        }

                        def tagFlags = "-t ${env.FULL_IMMUTABLE_REF}"
                        if (params.PUSH_TO_DOCKER_HUB) {
                            tagFlags = "${tagFlags} -t ${env.FULL_ALIAS_REF}"
                        }

                        sh """
                            set -eu
                            cd sandbox-build
                            docker buildx build \\
                                --builder '${builderName}' \\
                                --platform '${params.ARCHS}' \\
                                ${tagFlags} \\
                                --build-arg MONGO_REPO='${params.MONGO_REPO}' \\
                                --build-arg MONGO_BRANCH='${params.MONGO_BRANCH}' \\
                                --build-arg PSMDB_VERSION='${params.PSMDB_VERSION}' \\
                                --build-arg CACHE_BUST=${env.BUILD_NUMBER} \\
                                --provenance=false \\
                                ${pushFlag} \\
                                .
                        """

                        if (params.PUSH_TO_DOCKER_HUB) {
                            sh """
                                set -eu
                                echo "===== Verifying pushed manifest ====="
                                docker buildx imagetools inspect '${env.FULL_IMMUTABLE_REF}'
                            """
                        }
                    } finally {
                        sh """
                            set +e
                            docker buildx rm '${builderName}' 2>/dev/null || true
                        """
                    }
                }
            }
        }

        stage('Summary') {
            steps {
                script {
                    echo "===== Sandbox build SUCCESS ====="
                    echo "Image (immutable) : ${env.FULL_IMMUTABLE_REF}"
                    if (params.PUSH_TO_DOCKER_HUB) {
                        echo "Moving alias     : ${env.FULL_ALIAS_REF}"
                    }
                    echo ""
                    echo "Next steps:"
                    echo "  1. Add a row to bazel/platforms/psmdb_rbe_containers.bzl in the matching"
                    echo "     percona-server-mongodb branch (key = upstream distro_or_os name):"
                    echo ""
                    echo "       \"<distro_or_os>\": {"
                    echo "           \"container-url\": \"docker://${env.FULL_IMMUTABLE_REF}\","
                    echo "       },"
                    echo ""
                    echo "  2. Add the matching pool entry to"
                    echo "     IaC/buildbarn/ondemand/compose/config/ondemand-pools.yaml,"
                    echo "     using runner_image=${env.FULL_IMMUTABLE_REF} and bazel_pool_value="
                    echo "     <x86_64|aarch64> per registered worker arch."
                    echo ""
                    echo "  3. Re-run create-central.sh to roll the new pool to the BB scheduler."
                }
            }
        }
    }
}
