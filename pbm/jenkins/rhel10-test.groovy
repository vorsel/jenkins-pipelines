library changelog: false, identifier: 'lib@PKG-731_psmdb.cd_pbm_rhel10_support', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/vorsel/jenkins-pipelines.git'
]) _

void buildStage(String containerName = null, String DOCKER_OS, String STAGE_PARAM) {
    sh """
        set -o xtrace
        mkdir -p test
        wget \$(echo ${params.GIT_REPO} | sed -re 's|github.com|raw.githubusercontent.com|; s|\\.git\$||')/${params.GIT_BRANCH}/packaging/scripts/mongodb-backup_builder.sh -O mongodb-backup_builder.sh
        chmod +x mongodb-backup_builder.sh
        pwd -P
        ls -laR
    """
    def build_dir = sh(returnStdout: true, script: 'pwd -P').trim()
    def buildCommands = """
        set -o xtrace
        cd "${build_dir}"

        echo "Installing build dependencies..."
        bash -x ./mongodb-backup_builder.sh --builddir="${build_dir}/test" --install_deps=1

        echo "Running the build..."
        bash -x ./mongodb-backup_builder.sh \\
            --builddir="${build_dir}/test" \\
            --repo="${params.GIT_REPO}" \\
            --version="${params.VERSION}" \\
            --branch="${params.GIT_BRANCH}" \\
            --rpm_release="${params.RPM_RELEASE}" \\
            --deb_release="${params.DEB_RELEASE}" \\
            ${STAGE_PARAM}
    """.stripIndent()

    if (containerName) {
        echo "Executing build in existing container: ${containerName}"
        dockerUtils.execCommand(containerName, buildCommands, build_dir, "root")
    } else {
        echo "Executing build in a new container using image: ${DOCKER_OS}"
        def dockerRunCommand = "docker run -u root -v ${build_dir}:${build_dir} --rm ${DOCKER_OS} sh -c \"${buildCommands.replace('"', '\\"')}\""
        sh(dockerRunCommand)
    }
}

void cleanUpWS() {
    sh """
        sudo rm -rf ./*
    """
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
        RHEL10_AMD64_CONTAINER_NAME = 'rhel10_x64'
        RHEL10_ARM64_CONTAINER_NAME = 'rhel10_aarch64'
    }

    stages {
        stage('Create PBM source tarball') {
            when {
                expression { return params.BUILD_PACKAGES == 'true' }
            }
            agent {
                label params.CLOUD == 'Hetzner' ? 'docker-x64' : 'docker'
            }
            steps {
                slackNotify("#releases-ci", "#00FF00", "[${JOB_NAME}]: starting build for ${GIT_BRANCH} - [${BUILD_URL}]")
                cleanUpWS()
                buildStage("oraclelinux:8", "--get_sources=1")
                sh '''
                   REPO_UPLOAD_PATH=$(grep "UPLOAD" test/percona-backup-mongodb.properties | cut -d = -f 2 | sed "s:$:${BUILD_NUMBER}:")
                   AWS_STASH_PATH=$(echo ${REPO_UPLOAD_PATH} | sed  "s:UPLOAD/experimental/::")
                   echo ${REPO_UPLOAD_PATH} > uploadPath
                   echo ${AWS_STASH_PATH} > awsUploadPath
                   cat test/percona-backup-mongodb.properties
                   cat uploadPath
                '''
                script {
                    AWS_STASH_PATH = sh(returnStdout: true, script: "cat awsUploadPath").trim()
                }
                stash includes: 'uploadPath', name: 'uploadPath'
                pushArtifactFolder(params.CLOUD, "source_tarball/", AWS_STASH_PATH)
                uploadTarballfromAWS(params.CLOUD, "source_tarball/", AWS_STASH_PATH, 'source')
            }
        }
        stage('Build PBM generic source packages') {
            when {
                expression { return params.BUILD_PACKAGES == 'true' }
            }
            parallel {
                stage('Build PBM generic source rpm') {
                    agent {
                        label params.CLOUD == 'Hetzner' ? 'docker-x64' : 'docker'
                    }
                    steps {
                        cleanUpWS()
                        popArtifactFolder(params.CLOUD, "source_tarball/", AWS_STASH_PATH)
                        buildStage("oraclelinux:8", "--build_src_rpm=1")

                        pushArtifactFolder(params.CLOUD, "srpm/", AWS_STASH_PATH)
                        uploadRPMfromAWS(params.CLOUD, "srpm/", AWS_STASH_PATH)
                    }
                }
                stage('Build PBM generic source deb') {
                    agent {
                        label params.CLOUD == 'Hetzner' ? 'docker-x64' : 'docker'
                    }
                    steps {
                        cleanUpWS()
                        popArtifactFolder(params.CLOUD, "source_tarball/", AWS_STASH_PATH)
                        buildStage("ubuntu:jammy", "--build_src_deb=1")

                        pushArtifactFolder(params.CLOUD, "source_deb/", AWS_STASH_PATH)
                        uploadDEBfromAWS(params.CLOUD, "source_deb/", AWS_STASH_PATH)
                    }
                }
            }  //parallel
        } // stage
        stage('RHEL 10 Builds') {
            parallel {
                stage('RHEL 10 (x86_64) Build with Subscription') {
                    agent {
                        label 'docker-x64'
                    }
                    steps {
                        script {
                            echo "DEBUG: Starting RHEL x86_64 build stage"
                            cleanUpWS()
                            popArtifactFolder(params.CLOUD, "srpm/", AWS_STASH_PATH)

                            dockerUtils.script = this
                            rhelUtils.script = this
                            rhelUtils.dockerUtils = dockerUtils

                            echo "DEBUG: Starting RHEL x86_64 build stage"
                            def build_dir = sh(returnStdout: true, script: 'set -x; pwd -P').trim()
                            echo "DEBUG: build_dir is ${build_dir}"

                            echo "DEBUG: Starting container ${env.RHEL10_AMD64_CONTAINER_NAME}"
                            dockerUtils.startContainer(env.RHEL10_AMD64_CONTAINER_NAME, "redhat/ubi10", "-v ${build_dir}:${build_dir}")
                            
                            echo "DEBUG: Enabling RHEL subscription"
                            rhelUtils.enableSubscription(env.RHEL10_AMD64_CONTAINER_NAME)
                            
                            echo "DEBUG: Running buildStage"
                            buildStage(env.RHEL10_AMD64_CONTAINER_NAME, "redhat/ubi10", "--build_rpm=1")
                            
                            echo "DEBUG: Disabling RHEL subscription"
                            rhelUtils.disableSubscription(env.RHEL10_AMD64_CONTAINER_NAME)
                            echo "DEBUG: Finished RHEL x86_64 build stage"

                            pushArtifactFolder(params.CLOUD, "rpm/", AWS_STASH_PATH)
                            uploadRPMfromAWS(params.CLOUD, "rpm/", AWS_STASH_PATH)

                        }
                    }
                    post {
                        always {
                            script {
                                dockerUtils.stopContainer(env.RHEL10_AMD64_CONTAINER_NAME)
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
                            cleanUpWS()
                            popArtifactFolder(params.CLOUD, "srpm/", AWS_STASH_PATH)

                            dockerUtils.script = this
                            rhelUtils.script = this
                            rhelUtils.dockerUtils = dockerUtils
                            
                            echo "DEBUG: Starting RHEL aarch64 build stage"
                            def build_dir = sh(returnStdout: true, script: 'set -x; pwd -P').trim()
                            echo "DEBUG: build_dir is ${build_dir}"

                            echo "DEBUG: Starting container ${env.RHEL10_ARM64_CONTAINER_NAME}"
                            dockerUtils.startContainer(env.RHEL10_ARM64_CONTAINER_NAME, "redhat/ubi10", "-v ${build_dir}:${build_dir}")

                            echo "DEBUG: Enabling RHEL subscription"
                            rhelUtils.enableSubscription(env.RHEL10_ARM64_CONTAINER_NAME)

                            echo "DEBUG: Running buildStage"
                            buildStage(env.RHEL10_ARM64_CONTAINER_NAME, "redhat/ubi10", "--build_rpm=1")

                            echo "DEBUG: Disabling RHEL subscription"
                            rhelUtils.disableSubscription(env.RHEL10_ARM64_CONTAINER_NAME)
                            echo "DEBUG: Finished RHEL aarch64 build stage"

                            pushArtifactFolder(params.CLOUD, "rpm/", AWS_STASH_PATH)
                            uploadRPMfromAWS(params.CLOUD, "rpm/", AWS_STASH_PATH)
                        }
                    }
                    post {
                        always {
                            script {
                                dockerUtils.stopContainer(env.RHEL10_ARM64_CONTAINER_NAME)
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
