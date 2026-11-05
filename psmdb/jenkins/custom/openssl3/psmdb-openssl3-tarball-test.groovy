library changelog: false, identifier: 'lib@hetzner', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/Percona-Lab/jenkins-pipelines.git'
]) _

// Tests a hetzner-psmdb-openssl3-tarball build on every OS of os-matrix.json.
//   A (containers): OS images as containers on the agent, host kernel
//   B (vms):        one EC2 VM per OS, own kernel; runs only if A passed
// vendor bundle: private RepoCI path -> agent and test VMs only, never S3 or archived artifacts

def D = 'psmdb/jenkins/custom/openssl3'
def S = "${D}/scripts"
def M = "${D}/os-matrix.json"

void vmTest(String id, int idx, String S, String M) {
    stage("vm ${id}") {
        for (int attempt = 1; attempt <= 2; attempt++) {
            // second attempt only after a spot interruption, and then on-demand
            String od = (attempt > 1 || params.FORCE_ON_DEMAND) ? '1' : '0'
            def vm = sh(returnStdout: true, script: "FORCE_ON_DEMAND=${od} bash ${S}/ec2_vm.sh launch ${M} ${params.ARCH} ${id} ${env.TAG}").trim().split()
            String iid = vm[0], ip = vm[1], user = vm[2], life = vm[3], ami = vm[4], region = vm[5]
            echo "${id}: ${iid} ${region} ${life} ${ami} ${ip}"
            int rc
            try {
                rc = sh(returnStatus: true, script: """
                    bash ${S}/wait_ssh.sh ${ip} ${user} \$MOLECULE_AWS_PRIVATE_KEY
                    T=\$WORKSPACE/t OUT=\$WORKSPACE/results/vm OPENSSL_VERSION=${params.OPENSSL_VERSION} \
                        bash ${S}/verify_os.sh ssh ${id} ${idx} ${ip} ${user} \$MOLECULE_AWS_PRIVATE_KEY
                    printf '%s\\tami\\tINFO\\t%s %s %s %s\\n' ${id} ${ami} ${region} ${life} ${iid} >> \$WORKSPACE/results/vm/\$(printf %02d ${idx})-${id}.tsv
                """)
            } finally {
                sh "bash ${S}/ec2_vm.sh terminate ${region} ${iid} || true"
            }
            if (sh(returnStatus: true, script: "bash ${S}/ec2_vm.sh lost ${region} ${iid}") != 0) {
                if (rc != 0) { error("${id}: VM not reachable or test runner failed (rc ${rc})") }
                return
            }
            echo "${id}: spot instance reclaimed during the test, retrying this OS on-demand"
        }
        error("${id}: lost the VM twice")
    }
}

pipeline {
    agent {
        // one agent for the whole run: helper container, test files and ssh tunnels live here
        label 'docker-64gb'
    }
    environment {
        TAG = "oscheck-${env.BUILD_NUMBER}"
        // per-region subnet/SG/key: os-matrix.json .networks
        AWS_DEFAULT_REGION = 'us-west-2'
        // as PSMDB molecule; untagged VMs get killed by the cleanup lambda in 10 min
        BILLING_TAG = 'jenkins-psmdb-worker'
    }
    parameters {
        string(name: 'UPLOAD_PATH', defaultValue: '',
            description: 'RepoCI path of the build, e.g. /srv/UPLOAD/experimental/BUILDS/PSMDB_OPENSSL3_FIPS/CUSTOM123/7 (binary/tarball/ under it)')
        string(name: 'OPENSSL_VERSION', defaultValue: '3.5.9',
            description: 'Expected runtime OpenSSL of mongod')
        choice(name: 'ARCH', choices: ['x86_64'], description: 'Matrix section')
        choice(name: 'LEVEL', choices: ['containers', 'containers+vms', 'vms'],
            description: 'containers: every build; vms: own kernels, for release candidates')
        string(name: 'OS_LIST', defaultValue: 'all',
            description: "'all' or space-separated ids from os-matrix.json, e.g. 'resolute sles16' to rerun only those")
        string(name: 'VENDOR_BUNDLE', defaultValue: '/srv/UPLOAD/experimental/BUILDS/PSMDB_OPENSSL3_FIPS/vendor-bundle.zip',
            description: 'Customer runtime bundle on RepoCI, private dir with no sync to downloads. Empty = test only with our runtime libs')
        string(name: 'VENDOR_BUNDLE_SHA256', defaultValue: 'a464af76a429f0d787a2ff4ac90882f449a74e34542d8e69642e2154a3d86986',
            description: 'sha256 of the bundle zip')
        booleanParam(name: 'FORCE_ON_DEMAND', defaultValue: false,
            description: 'VMs on-demand from the start (no spot)')
        booleanParam(name: 'PUBLISH_TO_TESTING', defaultValue: false,
            description: 'On full success copy binary/tarball/ to downloads TESTING/issue-<JIRA_TASK>')
        string(name: 'JIRA_TASK', defaultValue: '', description: 'CUSTOM<digits>, used only for publishing')
    }
    options {
        skipDefaultCheckout()
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '30'))
        timestamps()
        timeout(time: 3, unit: 'HOURS')
    }
    stages {
        stage('Fetch and prepare') {
            steps {
                script {
                    if (!params.UPLOAD_PATH?.trim()) { error('UPLOAD_PATH is empty') }
                    currentBuild.description = "${params.UPLOAD_PATH} ${params.LEVEL} ${params.OS_LIST}"
                }
                sh 'sudo rm -rf ./* || true'
                checkout scm
                withCredentials([sshUserPrivateKey(credentialsId: 'repo.ci.percona.com', keyFileVariable: 'KEY_PATH', usernameVariable: 'USER')]) {
                    sh """
                        set -o xtrace
                        cat /etc/hosts > hosts
                        echo '10.30.6.9 repo.ci.percona.com' >> hosts
                        sudo cp ./hosts /etc || true
                        mkdir -p dl
                        scp -o StrictHostKeyChecking=no -i \${KEY_PATH} "\${USER}@repo.ci.percona.com:${params.UPLOAD_PATH}/binary/tarball/*" dl/
                        if [ -n '${params.VENDOR_BUNDLE}' ]; then
                            scp -o StrictHostKeyChecking=no -i \${KEY_PATH} "\${USER}@repo.ci.percona.com:${params.VENDOR_BUNDLE}" vendor.zip
                            echo '${params.VENDOR_BUNDLE_SHA256}  vendor.zip' | sha256sum -c -
                        fi
                    """
                }
                sh """
                    set -o xtrace
                    (cd dl && sha256sum -c ./*.sha256)
                    T=\$WORKSPACE/t; mkdir -p \$T/pkg \$T/rt
                    for f in dl/*.tar.gz; do
                        case \$f in
                            *-runtime-libs.tar.gz) tar xzf \$f -C \$T/rt --strip-components=1 ;;
                            *) tar xzf \$f -C \$T/pkg ;;
                        esac
                    done
                    if [ -f vendor.zip ]; then
                        mkdir vtmp && (unzip -q vendor.zip -d vtmp || python3 -m zipfile -e vendor.zip vtmp)
                        mv vtmp/*/ \$T/vendor && rm -rf vtmp vendor.zip
                    fi
                    ls \$T \$T/pkg/*/bin
                    T=\$T bash ${S}/helper_setup.sh
                """
            }
        }
        stage('A: containers') {
            when { expression { return params.LEVEL.contains('containers') } }
            steps {
                sh "T=\$WORKSPACE/t OUT=\$WORKSPACE/results/containers OPENSSL_VERSION=${params.OPENSSL_VERSION} bash ${S}/test_containers.sh ${M} ${params.ARCH} '${params.OS_LIST}'"
            }
        }
        stage('B: VMs') {
            when { expression { return params.LEVEL.contains('vms') } }
            steps {
                // same creds as PSMDB/PBM molecule
                withCredentials(moleculePbmJenkinsCreds()) {
                    script {
                        def matrix = readJSON file: M
                        def wanted = params.OS_LIST.trim() == 'all' ? null : params.OS_LIST.trim().split(/\s+/) as List
                        def branches = [failFast: false]
                        matrix[params.ARCH].eachWithIndex { os, i ->
                            if (wanted == null || wanted.contains(os.id)) {
                                String id = os.id
                                int idx = i + 1
                                branches[id] = { vmTest(id, idx, S, M) }
                            }
                        }
                        // one OS failing or losing its VM doesn't stop the others; rerun it alone with OS_LIST
                        parallel branches
                    }
                }
                sh "cat \$WORKSPACE/results/vm/*.tsv > \$WORKSPACE/results/vm/results.tsv; bash ${S}/summary.sh \$WORKSPACE/results/vm/results.tsv"
            }
        }
        stage('Publish to TESTING') {
            when { expression { return params.PUBLISH_TO_TESTING } }
            steps {
                script {
                    if (!(params.JIRA_TASK ==~ /CUSTOM\d+/)) { error('JIRA_TASK must be CUSTOM<digits> to publish') }
                    writeFile file: 'uploadPath', text: params.UPLOAD_PATH
                    stash includes: 'uploadPath', name: 'uploadPath'
                    uploadTarballToDownloadsTesting('AWS', 'issue', params.JIRA_TASK)
                }
            }
        }
    }
    post {
        always {
            archiveArtifacts artifacts: 'results/**/*.tsv,results/**/*.log,results/**/summary.txt', allowEmptyArchive: true
            // VMs left by an aborted run
            script {
                if (params.LEVEL.contains('vms')) {
                    withCredentials(moleculePbmJenkinsCreds()) {
                        sh "bash ${S}/ec2_vm.sh sweep ${M} ${env.TAG} || true"
                    }
                }
            }
            sh 'docker rm -f oscheck-helper $(docker ps -aq --filter name=oscheck-) >/dev/null 2>&1 || true; sudo rm -rf ./* || true'
            deleteDir()
        }
    }
}
