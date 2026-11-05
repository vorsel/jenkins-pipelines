library changelog: false, identifier: 'lib@hetzner', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/Percona-Lab/jenkins-pipelines.git'
]) _

// PSMDB tarball linked against a given OpenSSL 3 (not bundled), glibc 2.28 baseline,
// plus runtime libs, manifest and SBOMs -> RepoCI <REPOCI_BASE>/<JIRA_TASK>/<BUILD_NUMBER>/
// no RBE: its workers have no OpenSSL 3 under MONGO_OPENSSL_ROOT

def D = 'psmdb/jenkins/custom/openssl3'
// private dir, no sync to downloads; the customer bundle for tests sits here too
def REPOCI_BASE = '/srv/UPLOAD/experimental/BUILDS/PSMDB_OPENSSL3_FIPS'
def UPLOAD_PATH

pipeline {
    agent {
        label 'micro-amazon'
    }
    parameters {
        string(name: 'PSMDB_REPO', defaultValue: 'https://github.com/percona/percona-server-mongodb.git',
            description: 'PSMDB repository')
        string(name: 'PSMDB_TAG', defaultValue: 'psmdb-8.0.34-15',
            description: 'Tag to build. Needs MONGO_OPENSSL_ROOT support (8.0.34+), the job checks it')
        string(name: 'OPENSSL_VERSION', defaultValue: '3.5.9',
            description: 'OpenSSL release to build and link against (github.com/openssl/openssl releases)')
        string(name: 'OPENSSL_SHA256', defaultValue: '',
            description: 'sha256 of openssl-<ver>.tar.gz. Empty = take the .sha256 published with the release')
        choice(name: 'PROFILE', choices: ['openssl3-fips'],
            description: 'Runtime libs profile: profiles/<name>.env (versions, source sha256, expected NEEDED)')
        choice(name: 'ARCH', choices: ['x86_64'],
            description: 'aarch64 later')
        string(name: 'JIRA_TASK', defaultValue: 'CUSTOM000',
            description: 'CUSTOM<digits>. RepoCI path /srv/UPLOAD/experimental/BUILDS/PSMDB_OPENSSL3_FIPS/<JIRA_TASK>/<BUILD_NUMBER>, downloads TESTING/issue-<JIRA_TASK> on publish')
        booleanParam(name: 'RUN_TESTS', defaultValue: true,
            description: 'Start hetzner-psmdb-openssl3-tarball-test on the result')
        choice(name: 'TEST_LEVEL', choices: ['containers', 'containers+vms', 'vms'],
            description: 'Passed to the test job')
    }
    options {
        skipDefaultCheckout()
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '20'))
        timestamps()
        timeout(time: 4, unit: 'HOURS')
    }
    stages {
        stage('Build in fresh OL8') {
            agent {
                // spot; no on-demand docker label on psmdb.cd
                label 'docker-64gb'
            }
            options {
                // rerun the stage if the spot agent is reclaimed mid-build
                retry(count: 2, conditions: [agent(), nonresumable()])
            }
            steps {
                script {
                    if (!(params.JIRA_TASK ==~ /CUSTOM\d+/)) { error("JIRA_TASK must be CUSTOM<digits>") }
                    UPLOAD_PATH = "${REPOCI_BASE}/${params.JIRA_TASK}/${env.BUILD_NUMBER}"
                    currentBuild.description = "${params.PSMDB_TAG} openssl ${params.OPENSSL_VERSION} ${params.ARCH}"
                }
                slackNotify("#releases-ci", "#00FF00", "[${JOB_NAME}]: building ${params.PSMDB_TAG} with OpenSSL ${params.OPENSSL_VERSION} - [${BUILD_URL}]")
                sh 'sudo rm -rf ./* || true'
                checkout scm
                // builder from the same tag knows that version's build deps;
                // fresh base image every time on purpose, no stale packages
                sh """
                    set -o xtrace
                    wget -q \$(echo ${params.PSMDB_REPO} | sed -re 's|github.com|raw.githubusercontent.com|; s|\\.git\$||')/${params.PSMDB_TAG}/percona-packaging/scripts/psmdb_builder.sh -O psmdb_builder.sh
                    docker pull oraclelinux:8
                    export build_dir=\$(pwd -P)
                    docker run --rm -u root -v \${build_dir}:\${build_dir} -w \${build_dir} \
                        -e WORK=\${build_dir}/work \
                        -e PROFILE=\${build_dir}/${D}/profiles/${params.PROFILE}.env \
                        -e OPENSSL_VERSION='${params.OPENSSL_VERSION}' -e OPENSSL_SHA256='${params.OPENSSL_SHA256}' \
                        -e PSMDB_REPO='${params.PSMDB_REPO}' -e PSMDB_TAG='${params.PSMDB_TAG}' \
                        -e ARCH='${params.ARCH}' -e BUILD_URL='${env.BUILD_URL}' \
                        -e HOST_UID=\$(id -u) -e HOST_GID=\$(id -g) \
                        oraclelinux:8 bash -c '
                            set -e
                            mkdir -p work test
                            bash -x ./psmdb_builder.sh --builddir=\$WORK/../test --install_deps=1
                            bash -x ${D}/scripts/build_runtime_deps.sh
                            bash -x ${D}/scripts/build_psmdb.sh
                            bash ${D}/scripts/check_and_package.sh
                            chown -R \$HOST_UID:\$HOST_GID work/out'
                    ls -la work/out
                """
                archiveArtifacts artifacts: 'work/out/*.json,work/out/*.sha256', allowEmptyArchive: false
                withCredentials([sshUserPrivateKey(credentialsId: 'repo.ci.percona.com', keyFileVariable: 'KEY_PATH', usernameVariable: 'USER')]) {
                    sh """
                        cat /etc/hosts > hosts
                        echo '10.30.6.9 repo.ci.percona.com' >> hosts
                        sudo cp ./hosts /etc || true
                        ssh -o StrictHostKeyChecking=no -i \${KEY_PATH} \${USER}@repo.ci.percona.com mkdir -p ${UPLOAD_PATH}/binary/tarball
                        scp -o StrictHostKeyChecking=no -i \${KEY_PATH} work/out/* \${USER}@repo.ci.percona.com:${UPLOAD_PATH}/binary/tarball/
                    """
                }
            }
            post {
                always {
                    sh 'sudo rm -rf ./* || true'
                    deleteDir()
                }
            }
        }
        stage('Start tests') {
            when { expression { return params.RUN_TESTS } }
            steps {
                build job: 'hetzner-psmdb-openssl3-tarball-test', wait: false, parameters: [
                    string(name: 'UPLOAD_PATH', value: UPLOAD_PATH),
                    string(name: 'OPENSSL_VERSION', value: params.OPENSSL_VERSION),
                    string(name: 'ARCH', value: params.ARCH),
                    string(name: 'LEVEL', value: params.TEST_LEVEL),
                    string(name: 'JIRA_TASK', value: params.JIRA_TASK),
                ]
            }
        }
    }
    post {
        success {
            slackNotify("#releases-ci", "#00FF00", "[${JOB_NAME}]: ${params.PSMDB_TAG} + OpenSSL ${params.OPENSSL_VERSION} built, RepoCI ${UPLOAD_PATH} - [${BUILD_URL}]")
        }
        failure {
            slackNotify("#releases-ci", "#FF0000", "[${JOB_NAME}]: build failed for ${params.PSMDB_TAG} + OpenSSL ${params.OPENSSL_VERSION} - [${BUILD_URL}]")
        }
    }
}
