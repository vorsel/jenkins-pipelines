library changelog: false, identifier: 'lib@PKG-731_psmdb.cd_pbm_rhel10_support', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/vorsel/jenkins-pipelines.git'
]) _

void buildStage(String DOCKER_OS, String STAGE_PARAM, String containerName = null) {
    sh """
        set -o xtrace
        mkdir -p test
        wget \$(echo \${params.GIT_REPO} | sed -re 's|github.com|raw.githubusercontent.com|; s|\\.git\$||')/\${params.GIT_BRANCH}/packaging/scripts/mongodb-backup_builder.sh -O mongodb-backup_builder.sh
        chmod +x mongodb-backup_builder.sh
        pwd -P
        ls -laR
    """
    def build_dir = sh(returnStdout: true, script: 'pwd -P').trim()
    def buildCommands = "set -o xtrace; cd ${build_dir}; bash -x ./mongodb-backup_builder.sh --builddir=${build_dir}/test --install_deps=1; bash -x ./mongodb-backup_builder.sh --builddir=${build_dir}/test --repo=${params.GIT_REPO} --version=${params.VERSION} --branch=${params.GIT_BRANCH} --rpm_release=${params.RPM_RELEASE} --deb_release=${params.DEB_RELEASE} ${STAGE_PARAM}"

    if (containerName) {
        echo "Executing build in existing container: ${containerName}"
        dockerUtils.execCommand(containerName, buildCommands, build_dir, "root")
    } else {
        echo "Executing build in a new container using image: ${DOCKER_OS}"
        def dockerRunCommand = "docker run -u root -v ${build_dir}:${build_dir} --rm ${DOCKER_OS} sh -c \"${buildCommands}\""
        sh(dockerRunCommand)
    }
}

pipeline {
    agent {
        label 'launcher-x64'
    }
    parameters {
        choice(
            choices: ['Hetzner','AWS'],
            description: 'Cloud infra for build',
            name: 'CLOUD')
        string(
            defaultValue: 'https://github.com/percona/percona-backup-mongodb.git',
            description: 'URL for percona-mongodb-backup repository',
            name: 'GIT_REPO')
        string(
            defaultValue: 'dev',
            description: 'Tag/Branch for percona-mongodb-backup repository',
            name: 'GIT_BRANCH')
        string(
            defaultValue: '1',
            description: 'RPM release value',
            name: 'RPM_RELEASE')
        string(
            defaultValue: '1',
            description: 'DEB release value',
            name: 'DEB_RELEASE')
        string(
            defaultValue: '2.8.0',
            description: 'VERSION value',
            name: 'VERSION')
        string(
            defaultValue: 'pbm',
            description: 'PBM repo name',
            name: 'PBM_REPO')
        choice(
            choices: 'experimental\nlaboratory\ntesting\nexperimental',
            description: 'Repo component to push packages to',
            name: 'COMPONENT')
        choice(
            name: 'BUILD_DOCKER',
            choices: ['true', 'false'],
            description: 'Build and push Docker images (default: true)')
        choice(
            name: 'BUILD_PACKAGES',
            choices: ['true', 'false'],
            description: 'Build packages (default: true)')
        choice(
            name: 'TARGET_REPO',
            choices: ['PerconaLab','DockerHub'],
            description: 'Target repo for docker image, use DockerHub for release only')
        choice(
            name: 'PBM_REPO_TYPE',
            choices: ['testing','release','experimental'],
            description: 'Packages repo for docker images')
    }

    environment {
        RHEL_X64_CONTAINER = 'rhel10_x64'
        RHEL_AARCH64_CONTAINER = 'rhel10_aarch64'
    }

    stages {
        stage('RHEL 10 Builds') {
            parallel {
                stage('RHEL 10 (x86_64) Build with Subscription') {
                    agent {
                        label 'docker-x64'
                    }
                    steps {
                        script {
                            echo "DEBUG: Starting RHEL x86_64 build stage"
                            dockerUtils.script = this
                            rhelUtils.script = this
                            rhelUtils.dockerUtils = dockerUtils

                            echo "DEBUG: Starting RHEL x86_64 build stage"
                            def build_dir = sh(returnStdout: true, script: 'set -x; pwd -P').trim()
                            echo "DEBUG: build_dir is ${build_dir}"

                            echo "DEBUG: Starting container ${env.RHEL_X64_CONTAINER}"
                            dockerUtils.startContainer(env.RHEL_X64_CONTAINER, "redhat/ubi10-minimal", "-v ${build_dir}:${build_dir}")
                            
                            echo "DEBUG: Enabling RHEL subscription"
                            rhelUtils.enableSubscription(env.RHEL_X64_CONTAINER)
                            
                            echo "DEBUG: Running buildStage"
                            buildStage("redhat/ubi10-minimal", "--build_rpm=1", env.RHEL_X64_CONTAINER)
                            
                            echo "DEBUG: Disabling RHEL subscription"
                            rhelUtils.disableSubscription(env.RHEL_X64_CONTAINER)
                            echo "DEBUG: Finished RHEL x86_64 build stage"
                        }
                    }
                    post {
                        always {
                            script {
                                dockerUtils.stopContainer(env.RHEL_X64_CONTAINER)
                            }
                        }
                    }
                }
                stage('RHEL 10 (aarch64) Build with Subscription') {
                    agent {
                        label 'docker-aarch64'
                    }
                    steps {
                        script {
                            echo "DEBUG: Starting RHEL aarch64 build stage"
                            dockerUtils.script = this
                            rhelUtils.script = this
                            rhelUtils.dockerUtils = dockerUtils
                            
                            echo "DEBUG: Starting RHEL aarch64 build stage"
                            def build_dir = sh(returnStdout: true, script: 'set -x; pwd -P').trim()
                            echo "DEBUG: build_dir is ${build_dir}"

                            echo "DEBUG: Starting container ${env.RHEL_AARCH64_CONTAINER}"
                            dockerUtils.startContainer(env.RHEL_AARCH64_CONTAINER, "redhat/ubi10-minimal", "-v ${build_dir}:${build_dir}")

                            echo "DEBUG: Enabling RHEL subscription"
                            rhelUtils.enableSubscription(env.RHEL_AARCH64_CONTAINER)

                            echo "DEBUG: Running buildStage"
                            buildStage("redhat/ubi10-minimal", "--build_rpm=1", env.RHEL_AARCH64_CONTAINER)

                            echo "DEBUG: Disabling RHEL subscription"
                            rhelUtils.disableSubscription(env.RHEL_AARCH64_CONTAINER)
                            echo "DEBUG: Finished RHEL aarch64 build stage"
                        }
                    }
                    post {
                        always {
                            script {
                                dockerUtils.stopContainer(env.RHEL_AARCH64_CONTAINER)
                            }
                        }
                    }
                }
            }
        }
        stage('Ubuntu Build (no subscription)') {
            agent {
                label 'docker'
            }
            steps {
                script {
                    buildStage("ubuntu:22.04", "--build_deb=1")
                }
            }
        }
    }
}
