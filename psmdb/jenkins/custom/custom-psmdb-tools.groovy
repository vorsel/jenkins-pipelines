library changelog: false, identifier: 'lib@hetzner', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/Percona-Lab/jenkins-pipelines.git'
]) _

// Custom rebuild of a released percona-server-mongodb-tools for an OS the
// regular tools job doesn't cover (el7, Debian 11). Takes the released sources
// from downloads, so no --get_sources and no properties file.
void buildStage(String DOCKER_OS, String STAGE_PARAM) {
    sh """
        set -o xtrace
        rm -rf test/* tools-packaging
        mkdir -p test

        wget \$(echo ${BUILD_GIT_REPO} | sed -re 's|\\.git\$||')/archive/${BUILD_GIT_BRANCH}.tar.gz -O packaging.tar.gz
        tar zxf packaging.tar.gz
        mv percona-mongodb-tools-packaging-* tools-packaging
        rm -f packaging.tar.gz

        pwd -P
        export build_dir=\$(pwd -P)
        docker run -u root -v \${build_dir}:\${build_dir} ${DOCKER_OS} sh -c "
            set -o xtrace
            cd \${build_dir}
            bash -x ./tools-packaging/scripts/mongo_tools_builder.sh --builddir=\${build_dir}/test --install_deps=1
            bash -x ./tools-packaging/scripts/mongo_tools_builder.sh --builddir=\${build_dir}/test ${STAGE_PARAM}"
    """
}

// fetch the released sources the chosen build needs into the dirs the builder looks in
void fetchSources(boolean tarball, boolean rpm, boolean deb) {
    def v = "${params.TOOLS_VERSION}"
    def vr = "${params.TOOLS_VERSION}-${params.TOOLS_RELEASE}"
    def base = params.SOURCE_BASE_URL.replaceAll('/+$', '')
    def files = []
    if (tarball) {
        files << ["source_tarball", "${base}/tarball/percona-server-mongodb-tools-${vr}.tar.gz"]
    }
    if (rpm) {
        files << ["srpm", "${base}/redhat/percona-server-mongodb-tools-${vr}.generic.src.rpm"]
    }
    if (deb) {
        files << ["source_deb", "${base}/debian/percona-server-mongodb-tools_${vr}.dsc"]
        files << ["source_deb", "${base}/debian/percona-server-mongodb-tools_${v}.orig.tar.gz"]
        files << ["source_deb", "${base}/debian/percona-server-mongodb-tools_${vr}.debian.tar.xz"]
    }
    for (f in files) {
        sh """
            set -o xtrace
            mkdir -p ${f[0]}
            curl -fL '${f[1]}' -o ${f[0]}/\$(basename '${f[1]}')
        """
    }
    sh 'ls -la source_tarball srpm source_deb 2>/dev/null || true'
}

// no shared-library equivalent for rpms, same helper as custom-psmdb70-el7-rpm
void uploadRPMToDownloadsTesting(String cloudName, String productName, String productVersion) {
    def nodeLabel = (cloudName == 'Hetzner') ? 'launcher-x64' : 'master'
    node(nodeLabel) {
        deleteDir()
        unstash 'uploadPath'
        def pathToBuild = sh(returnStdout: true, script: "cat uploadPath").trim()
        withCredentials([sshUserPrivateKey(credentialsId: 'repo.ci.percona.com', keyFileVariable: 'KEY_PATH', usernameVariable: 'USER')]) {
            sh """
                #!/bin/bash
                set -o xtrace

                cat /etc/hosts > hosts
                echo '10.30.6.9 repo.ci.percona.com' >> hosts
                sudo cp ./hosts /etc || true

                cutProductVersion=\$(echo ${productVersion} | sed 's/release-//g');
                target_dir=/data/downloads/TESTING/${productName}-\${cutProductVersion}

                ssh -o StrictHostKeyChecking=no -i ${KEY_PATH} ${USER}@repo.ci.percona.com \
                    ssh -p 2222 jenkins-deploy.jenkins-deploy.web.r.int.percona.com mkdir -p \${target_dir}

                # flat file list: the downloads host doesn't let you descend into subfolders
                ssh -o StrictHostKeyChecking=no -i ${KEY_PATH} ${USER}@repo.ci.percona.com \
                    rsync -avt -e '"ssh -p 2222"' --bwlimit=50000 --progress ${pathToBuild}/binary/redhat/*/*/*.rpm jenkins-deploy.jenkins-deploy.web.r.int.percona.com:\${target_dir}/

                curl -k https://www.percona.com/admin/config/percona/percona_downloads/crawl_directory
            """
        }
        deleteDir()
    }
}

// same as uploadRPMToDownloadsTesting, for debs
void uploadDEBToDownloadsTesting(String cloudName, String productName, String productVersion) {
    def nodeLabel = (cloudName == 'Hetzner') ? 'launcher-x64' : 'master'
    node(nodeLabel) {
        deleteDir()
        unstash 'uploadPath'
        def pathToBuild = sh(returnStdout: true, script: "cat uploadPath").trim()
        withCredentials([sshUserPrivateKey(credentialsId: 'repo.ci.percona.com', keyFileVariable: 'KEY_PATH', usernameVariable: 'USER')]) {
            sh """
                #!/bin/bash
                set -o xtrace

                cat /etc/hosts > hosts
                echo '10.30.6.9 repo.ci.percona.com' >> hosts
                sudo cp ./hosts /etc || true

                cutProductVersion=\$(echo ${productVersion} | sed 's/release-//g');
                target_dir=/data/downloads/TESTING/${productName}-\${cutProductVersion}

                ssh -o StrictHostKeyChecking=no -i ${KEY_PATH} ${USER}@repo.ci.percona.com \
                    ssh -p 2222 jenkins-deploy.jenkins-deploy.web.r.int.percona.com mkdir -p \${target_dir}

                ssh -o StrictHostKeyChecking=no -i ${KEY_PATH} ${USER}@repo.ci.percona.com \
                    rsync -avt -e '"ssh -p 2222"' --bwlimit=50000 --progress ${pathToBuild}/binary/debian/*/*/*.deb jenkins-deploy.jenkins-deploy.web.r.int.percona.com:\${target_dir}/

                curl -k https://www.percona.com/admin/config/percona/percona_downloads/crawl_directory
            """
        }
        deleteDir()
    }
}

void cleanUpWS() {
    sh """
        sudo rm -rf ./*
    """
}

def AWS_STASH_PATH
def BUILD_TARBALL = false
def BUILD_PACKAGES = false
def IS_RPM = false

pipeline {
    agent {
        label params.CLOUD == 'Hetzner' ? 'launcher-x64' : 'micro-amazon'
    }
    parameters {
        choice(
            choices: ['Hetzner','AWS'],
            description: 'Cloud infra for build',
            name: 'CLOUD')
        choice(
            choices: ['centos:7', 'debian:bullseye'],
            description: 'OS to build for (docker image). centos:7 gives el7 rpms / .ol7 tarball, debian:bullseye gives Debian 11 debs / .bullseye tarball',
            name: 'TARGET_OS')
        choice(
            choices: ['tarball', 'packages', 'both'],
            description: 'What to build: binary tarball, rpm/deb packages (by TARGET_OS) or both',
            name: 'BUILD_TYPE')
        string(
            defaultValue: 'https://downloads.percona.com/downloads/percona-server-mongodb-7.0/percona-server-mongodb-7.0.48-25/source',
            description: 'Released source folder on downloads, with tarball/, redhat/ and debian/ inside. The tools sources sit in the PSMDB release they shipped with',
            name: 'SOURCE_BASE_URL')
        string(
            defaultValue: '100.20.1',
            description: 'Released tools version, e.g. 100.20.1',
            name: 'TOOLS_VERSION')
        string(
            defaultValue: '1',
            description: 'Released tools package release, e.g. 1 for 100.20.1-1',
            name: 'TOOLS_RELEASE')
        string(
            defaultValue: 'https://github.com/vorsel/percona-mongodb-tools-packaging.git',
            description: 'URL for the tools packaging repository to take mongo_tools_builder.sh from',
            name: 'BUILD_GIT_REPO')
        string(
            defaultValue: 'custom_tools_el7_deb11',
            description: 'Tag/Branch for the tools packaging repository',
            name: 'BUILD_GIT_BRANCH')
        string(
            defaultValue: 'CUSTOM273',
            description: 'Jira task name without dash(CUSTOM-273 -> CUSTOM273). Must be CUSTOM<digits>, otherwise issue-CUSTOM<digits> is not indexed on the downloads host',
            name: 'JIRA_TASK')
    }
    options {
        skipDefaultCheckout()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10', artifactNumToKeepStr: '10'))
        timestamps ()
    }
    stages {
        stage('Build') {
            agent {
                label params.CLOUD == 'Hetzner' ? 'docker-x64' : 'docker-64gb'
            }
            steps {
                script {
                    BUILD_TARBALL = params.BUILD_TYPE in ['tarball', 'both']
                    BUILD_PACKAGES = params.BUILD_TYPE in ['packages', 'both']
                    IS_RPM = params.TARGET_OS.startsWith('centos')
                }
                slackNotify("#releases-ci", "#00FF00", "[${JOB_NAME}]: starting ${BUILD_TYPE} build of tools ${TOOLS_VERSION}-${TOOLS_RELEASE} for ${TARGET_OS} - [${BUILD_URL}]")
                cleanUpWS()
                script {
                    fetchSources(BUILD_TARBALL, BUILD_PACKAGES && IS_RPM, BUILD_PACKAGES && !IS_RPM)
                    def args = []
                    if (BUILD_TARBALL) {
                        args << '--build_tarball=1'
                    }
                    if (BUILD_PACKAGES) {
                        args << (IS_RPM ? '--build_rpm=1' : '--build_deb=1')
                    }
                    buildStage(params.TARGET_OS, args.join(' '))

                    AWS_STASH_PATH = "${JIRA_TASK}/tools/${BUILD_NUMBER}"
                    writeFile file: 'uploadPath', text: "UPLOAD/experimental/${AWS_STASH_PATH}"
                    stash includes: 'uploadPath', name: 'uploadPath'

                    // pushArtifactFolder swallows aws errors, so fail here rather than
                    // silently publishing an empty folder
                    if (BUILD_TARBALL) {
                        sh 'ls -la tarball/ && test $(ls -1 tarball/*.tar.gz | wc -l) -gt 0'
                        pushArtifactFolder(params.CLOUD, "tarball/", AWS_STASH_PATH)
                    }
                    if (BUILD_PACKAGES && IS_RPM) {
                        sh 'ls -la rpm/ && test $(ls -1 rpm/*.el7.x86_64.rpm | wc -l) -gt 0'
                        pushArtifactFolder(params.CLOUD, "rpm/", AWS_STASH_PATH)
                    }
                    if (BUILD_PACKAGES && !IS_RPM) {
                        sh 'ls -la deb/ && test $(ls -1 deb/*.bullseye_amd64.deb | wc -l) -gt 0'
                        pushArtifactFolder(params.CLOUD, "deb/", AWS_STASH_PATH)
                    }
                }
            }
        }
        stage('Upload tarball from S3') {
            when {
                expression { BUILD_TARBALL }
            }
            steps {
                uploadTarballfromAWS(params.CLOUD, "tarball/", AWS_STASH_PATH, 'binary')
            }
        }
        stage('Upload and sign RPMs') {
            when {
                expression { BUILD_PACKAGES && IS_RPM }
            }
            steps {
                uploadRPMfromAWS(params.CLOUD, "rpm/", AWS_STASH_PATH)
                signRPM(params.CLOUD)
            }
        }
        stage('Upload and sign DEBs') {
            when {
                expression { BUILD_PACKAGES && !IS_RPM }
            }
            steps {
                uploadDEBfromAWS(params.CLOUD, "deb/", AWS_STASH_PATH)
                signDEB(params.CLOUD)
            }
        }
        stage('Push to TESTING download area') {
            steps {
                script {
                    try {
                        if (BUILD_TARBALL) {
                            uploadTarballToDownloadsTesting(params.CLOUD, "issue", "${JIRA_TASK}")
                        }
                        if (BUILD_PACKAGES && IS_RPM) {
                            uploadRPMToDownloadsTesting(params.CLOUD, "issue", "${JIRA_TASK}")
                        }
                        if (BUILD_PACKAGES && !IS_RPM) {
                            uploadDEBToDownloadsTesting(params.CLOUD, "issue", "${JIRA_TASK}")
                        }
                    }
                    catch (err) {
                        echo "Caught: ${err}"
                        currentBuild.result = 'UNSTABLE'
                    }
                }
            }
        }
    }
    post {
        success {
            slackNotify("#releases-ci", "#00FF00", "[${JOB_NAME}]: ${BUILD_TYPE} build of tools ${TOOLS_VERSION}-${TOOLS_RELEASE} for ${TARGET_OS} finished - [${BUILD_URL}]")
            script {
                currentBuild.description = "Tools ${TOOLS_VERSION}-${TOOLS_RELEASE}, ${TARGET_OS}, ${BUILD_TYPE}. Downloads: TESTING/issue-${JIRA_TASK}"
            }
            deleteDir()
        }
        failure {
            slackNotify("#releases-ci", "#FF0000", "[${JOB_NAME}]: ${BUILD_TYPE} build of tools ${TOOLS_VERSION}-${TOOLS_RELEASE} for ${TARGET_OS} failed - [${BUILD_URL}]")
            deleteDir()
        }
        always {
            sh '''
                sudo rm -rf ./*
            '''
            deleteDir()
        }
    }
}
