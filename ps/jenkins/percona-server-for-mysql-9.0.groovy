/* groovylint-disable DuplicateStringLiteral, GStringExpressionWithinString, LineLength */
library changelog: false, identifier: 'lib@master', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/Percona-Lab/jenkins-pipelines.git'
]) _

import groovy.transform.Field

void installCli(String PLATFORM) {
    sh """
        set -o xtrace
        if [ -d aws ]; then
            rm -rf aws
        fi
        if [ ${PLATFORM} = "deb" ]; then
            sudo apt-get update
            sudo apt-get -y install wget curl unzip
        elif [ ${PLATFORM} = "rpm" ]; then
            export RHVER=\$(rpm --eval %rhel)
            if [ \${RHVER} = "7" ]; then
                sudo sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-* || true
                sudo sed -i 's|#\\s*baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-* || true
                if [ -e "/etc/yum.repos.d/CentOS-SCLo-scl.repo" ]; then
                    cat /etc/yum.repos.d/CentOS-SCLo-scl.repo
                fi
            fi
            sudo yum -y install wget curl unzip
        fi
        curl https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip
        unzip awscliv2.zip
        sudo ./aws/install || true
    """
}

void buildStage(String DOCKER_OS, String STAGE_PARAM) {
    sh """
        set -o xtrace
        mkdir -p test
        wget \$(echo ${GIT_REPO} | sed -re 's|github.com|raw.githubusercontent.com|; s|\\.git\$||')/${BRANCH}/build-ps/percona-server-9.0_builder.sh -O ps_builder.sh || curl \$(echo ${GIT_REPO} | sed -re 's|github.com|raw.githubusercontent.com|; s|\\.git\$||')/${BRANCH}/build-ps/percona-server-9.0_builder.sh -o ps_builder.sh
        export build_dir=\$(pwd -P)
        if [ "$DOCKER_OS" = "none" ]; then
            set -o xtrace
            cd \${build_dir}
            if [ -f ./test/percona-server-9.0.properties ]; then
                . ./test/percona-server-9.0.properties
            fi
            sudo bash -x ./ps_builder.sh --builddir=\${build_dir}/test --install_deps=1
            bash -x ./ps_builder.sh --builddir=\${build_dir}/test --repo=${GIT_REPO} --branch=${BRANCH} --rpm_release=${RPM_RELEASE} --deb_release=${DEB_RELEASE} ${STAGE_PARAM}
        else
            docker run -u root -v \${build_dir}:\${build_dir} ${DOCKER_OS} sh -c "
                set -o xtrace
                cd \${build_dir}
                if [ -f ./test/percona-server-9.0.properties ]; then
                    . ./test/percona-server-9.0.properties
                fi
                bash -x ./ps_builder.sh --builddir=\${build_dir}/test --install_deps=1
                bash -x ./ps_builder.sh --builddir=\${build_dir}/test --repo=${GIT_REPO} --branch=${BRANCH} --rpm_release=${RPM_RELEASE} --deb_release=${DEB_RELEASE} ${STAGE_PARAM}"
        fi
    """
}

void cleanUpWS() {
    sh """
        sudo rm -rf ./*
    """
}

def installDependencies(def nodeName) {
    def aptNodes = ['min-bullseye-x64', 'min-bookworm-x64', 'min-focal-x64', 'min-jammy-x64', 'min-noble-x64']
    def yumNodes = ['min-ol-8-x64', 'min-centos-7-x64', 'min-ol-9-x64', 'min-amazon-2-x64']
    try{
        if (aptNodes.contains(nodeName)) {
            if(nodeName == "min-bullseye-x64" || nodeName == "min-bookworm-x64"){            
                sh '''
                    sudo apt-get update
                    sudo apt-get install -y ansible git wget
                '''
            }else if(nodeName == "min-focal-x64" || nodeName == "min-jammy-x64" || nodeName == "min-noble-x64"){
                sh '''
                    sudo apt-get update
                    sudo apt-get install -y software-properties-common
                    sudo apt-add-repository --yes --update ppa:ansible/ansible
                    sudo apt-get install -y ansible git wget
                '''
            }else {
                error "Node Not Listed in APT"
            }
        } else if (yumNodes.contains(nodeName)) {

            if(nodeName == "min-centos-7-x64" || nodeName == "min-ol-9-x64"){            
                sh '''
                    sudo yum install -y epel-release
                    sudo yum -y update
                    sudo yum install -y ansible git wget tar
                '''
            }else if(nodeName == "min-ol-8-x64"){
                sh '''
                    sudo yum install -y epel-release
                    sudo yum -y update
                    sudo yum install -y ansible-2.9.27 git wget tar
                '''
            }else if(nodeName == "min-amazon-2-x64"){
                sh '''
                    sudo amazon-linux-extras install epel
                    sudo yum -y update
                    sudo yum install -y ansible git wget
                '''
            }
            else {
                error "Node Not Listed in YUM"
            }
        } else {
            echo "Unexpected node name: ${nodeName}"
        }
    } catch (Exception e) {
        slackNotify("${SLACKNOTIFY}", "#FF0000", "[${JOB_NAME}]: Server Provision for Mini Package Testing for ${nodeName} at ${BRANCH}  FAILED !!")
    }

}

def runPlaybook(def nodeName) {

    try {
        def playbook = "ps_lts_innovation.yml"
        def playbook_path = "package-testing/playbooks/${playbook}"

        sh '''
            set -xe
            git clone --depth 1 https://github.com/Percona-QA/package-testing
        '''
        sh """
            set -xe
            export install_repo="\${install_repo}"
            export client_to_test="ps90"
            export check_warning="\${check_warnings}"
            export install_mysql_shell="\${install_mysql_shell}"
            ansible-playbook \
            --connection=local \
            --inventory 127.0.0.1, \
            --limit 127.0.0.1 \
            ${playbook_path}
        """
    } catch (Exception e) {
        slackNotify("${SLACKNOTIFY}", "#FF0000", "[${JOB_NAME}]: Mini Package Testing for ${nodeName} at ${BRANCH}  FAILED !!!")
        mini_test_error="True"
    }
}

def minitestNodes = [  "min-bullseye-x64",
                       "min-bookworm-x64",
                       "min-centos-7-x64",
                       "min-ol-8-x64",
                       "min-focal-x64",
                       "min-amazon-2-x64",
                       "min-jammy-x64",
                       "min-noble-x64",
                       "min-ol-9-x64"     ]

def package_tests_ps90(def nodes) {
    def stepsForParallel = [:]
    for (int i = 0; i < nodes.size(); i++) {
        def nodeName = nodes[i]
        stepsForParallel[nodeName] = {
            stage("Minitest run on ${nodeName}") {
                node(nodeName) {
                        installDependencies(nodeName)
                        runPlaybook(nodeName)
                }
            }
        }
    }
    parallel stepsForParallel
}

@Field def mini_test_error = "False"
def AWS_STASH_PATH
def PS8_RELEASE_VERSION
def product_to_test = 'innovation-lts'
def install_repo = 'testing'
def action_to_test = 'install'
def check_warnings = 'yes'
def install_mysql_shell = 'no'

pipeline {
    agent {
        label 'docker'
    }
parameters {
        string(defaultValue: 'https://github.com/percona/percona-server.git', description: 'github repository for build', name: 'GIT_REPO')
        string(defaultValue: 'release-9.0.1-1', description: 'Tag/Branch for percona-server repository', name: 'BRANCH')
        string(defaultValue: '1', description: 'RPM version', name: 'RPM_RELEASE')
        string(defaultValue: '1', description: 'DEB version', name: 'DEB_RELEASE')
        choice(
            choices: 'ON\nOFF',
            description: 'Compile with ZenFS support?, only affects Ubuntu Hirsute',
            name: 'ENABLE_ZENFS')
        choice(
            choices: 'NO\nYES',
            description: 'Enable fipsmode',
            name: 'FIPSMODE')
        choice(
            choices: 'YES\nNO',
            description: 'Experimental packages only',
            name: 'EXPERIMENTALMODE')
        choice(
            choices: 'laboratory\ntesting\nexperimental\nrelease',
            description: 'Repo component to push packages to',
            name: 'COMPONENT')
        choice(
            choices: '#releases\n#releases-ci',
            description: 'Channel for notifications',
            name: 'SLACKNOTIFY')
    }
    options {
        skipDefaultCheckout()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10', artifactNumToKeepStr: '10'))
        timestamps ()
    }
    stages {

        stage('Create PS source tarball') {
            agent {
               label 'min-focal-x64'
            }
            steps {
                slackNotify("${SLACKNOTIFY}", "#00FF00", "[${JOB_NAME}]: starting build for ${BRANCH} - [${BUILD_URL}]")
                cleanUpWS()
                installCli("deb")
                buildStage("none", "--get_sources=1")
                sh '''
                   REPO_UPLOAD_PATH=$(grep "UPLOAD" test/percona-server-9.0.properties | cut -d = -f 2 | sed "s:$:${BUILD_NUMBER}:")
                   AWS_STASH_PATH=$(echo ${REPO_UPLOAD_PATH} | sed  "s:UPLOAD/experimental/::")
                   echo ${REPO_UPLOAD_PATH} > uploadPath
                   echo ${AWS_STASH_PATH} > awsUploadPath
                   cat test/percona-server-9.0.properties
                   cat uploadPath
                   cat awsUploadPath
                '''
                script {
                    AWS_STASH_PATH = sh(returnStdout: true, script: "cat awsUploadPath").trim()
                }
                stash includes: 'uploadPath', name: 'uploadPath'
                stash includes: 'test/percona-server-9.0.properties', name: 'properties'
                pushArtifactFolder("source_tarball/", AWS_STASH_PATH)
                uploadTarballfromAWS("source_tarball/", AWS_STASH_PATH, 'source')
            }
        }
        stage('Build PS generic source packages') {
            parallel {
                stage('Build PS generic source rpm') {
                    agent {
                        label 'min-centos-7-x64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("rpm")
                        unstash 'properties'
                        popArtifactFolder("source_tarball/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                buildStage("none", "--build_src_rpm=1 --enable_fipsmode=1")
                            } else {
                                buildStage("none", "--build_src_rpm=1")
                            }
                        }
                        pushArtifactFolder("srpm/", AWS_STASH_PATH)
                        uploadRPMfromAWS("srpm/", AWS_STASH_PATH)
                    }
                }
                stage('Build PS generic source deb') {
                    agent {
                        label 'min-buster-x64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("deb")
                        unstash 'properties'
                        popArtifactFolder("source_tarball/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                buildStage("none", "--build_source_deb=1 --enable_fipsmode=1")
                            } else {
                                buildStage("none", "--build_source_deb=1")
                            }
                        }

                        pushArtifactFolder("source_deb/", AWS_STASH_PATH)
                        uploadDEBfromAWS("source_deb/", AWS_STASH_PATH)
                    }
                }
            }  //parallel
        } // stage
        stage('Build PS RPMs/DEBs/Binary tarballs') {
            parallel {
                stage('Oracle Linux 8') {
                    agent {
                        label 'min-ol-8-x64'
                    }
                    steps {
                        script {
                            if (env.FIPSMODE == 'YES') {
                                echo "The step is skipped"
                            } else {
                                cleanUpWS()
                                installCli("rpm")
                                unstash 'properties'
                                popArtifactFolder("srpm/", AWS_STASH_PATH)
                                buildStage("none", "--build_rpm=1")

                                if (env.EXPERIMENTALMODE == 'NO') {
                                    pushArtifactFolder("rpm/", AWS_STASH_PATH)
                                }
                            }
                        }
                    }
                }
                stage('Centos 8 ARM') {
                    agent {
                        label 'docker-32gb-aarch64'
                    }
                    steps {
                        script {
                            if (env.FIPSMODE == 'YES') {
                                echo "The step is skipped"
                            } else {
                                cleanUpWS()
                                installCli("rpm")
                                unstash 'properties'
                                popArtifactFolder("srpm/", AWS_STASH_PATH)
                                buildStage("centos:8", "--build_rpm=1")
                                if (env.EXPERIMENTALMODE == 'NO') {
                                    pushArtifactFolder("rpm/", AWS_STASH_PATH)
                                }
                            }
                        }
                    }
                }
                stage('Oracle Linux 9') {
                    agent {
                        label 'min-ol-9-x64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("rpm")
                        unstash 'properties'
                        popArtifactFolder("srpm/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                buildStage("none", "--build_rpm=1 --with_zenfs=1 --enable_fipsmode=1")
                            } else {
                                buildStage("none", "--build_rpm=1 --with_zenfs=1")
                            }
                            if (env.EXPERIMENTALMODE == 'NO') {
                                pushArtifactFolder("rpm/", AWS_STASH_PATH)
                            }
                        }
                    }
                }
                stage('Oracle Linux 9 ARM') {
                    agent {
                        label 'docker-32gb-aarch64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("rpm")
                        unstash 'properties'
                        popArtifactFolder("srpm/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                buildStage("oraclelinux:9", "--build_rpm=1 --enable_fipsmode=1")
                            } else {
                                buildStage("oraclelinux:9", "--build_rpm=1")
                            }
                            if (env.EXPERIMENTALMODE == 'NO') {
                                pushArtifactFolder("rpm/", AWS_STASH_PATH)
                            }
                        }
                    }
                }
                stage('Ubuntu Focal(20.04)') {
                    agent {
                        label 'min-focal-x64'
                    }
                    steps {
                        script {
                            if (env.FIPSMODE == 'YES') {
                                echo "The step is skipped"
                            } else {
                                cleanUpWS()
                                installCli("deb")
                                unstash 'properties'
                                popArtifactFolder("source_deb/", AWS_STASH_PATH)
                                buildStage("none", "--build_deb=1 --with_zenfs=1")
                                if (env.EXPERIMENTALMODE == 'NO') {
                                    pushArtifactFolder("deb/", AWS_STASH_PATH)
                                }
                            }
                        }
                    }
                }
                stage('Ubuntu Jammy(22.04)') {
                    agent {
                        label 'min-jammy-x64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("deb")
                        unstash 'properties'
                        popArtifactFolder("source_deb/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                buildStage("none", "--build_deb=1 --with_zenfs=1 --enable_fipsmode=1")
                            } else {
                                buildStage("none", "--build_deb=1 --with_zenfs=1")
                            }
                        }

                        pushArtifactFolder("deb/", AWS_STASH_PATH)
                    }
                }
                stage('Ubuntu Noble(24.04)') {
                    agent {
                        label 'min-noble-x64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("deb")
                        unstash 'properties'
                        popArtifactFolder("source_deb/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                buildStage("none", "--build_deb=1 --with_zenfs=1 --enable_fipsmode=1")
                            } else {
                                buildStage("none", "--build_deb=1 --with_zenfs=1")
                            }
                            if (env.EXPERIMENTALMODE == 'NO') {
                                pushArtifactFolder("deb/", AWS_STASH_PATH)
                            }
                        }
                    }
                }
                stage('Debian Bullseye(11)') {
                    agent {
                        label 'min-bullseye-x64'
                    }
                    steps {
                        script {
                            if (env.FIPSMODE == 'YES') {
                                echo "The step is skipped"
                            } else {
                                cleanUpWS()
                                installCli("deb")
                                unstash 'properties'
                                popArtifactFolder("source_deb/", AWS_STASH_PATH)
                                buildStage("none", "--build_deb=1 --with_zenfs=1")
                                if (env.EXPERIMENTALMODE == 'NO') {
                                    pushArtifactFolder("deb/", AWS_STASH_PATH)
                                }
                            }
                        }
                    }
                }
                stage('Debian Bookworm(12)') {
                    agent {
                        label 'min-bookworm-x64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("deb")
                        unstash 'properties'
                        popArtifactFolder("source_deb/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                buildStage("none", "--build_deb=1 --with_zenfs=1 --enable_fipsmode=1")
                            } else {
                                buildStage("none", "--build_deb=1 --with_zenfs=1")
                            }
                            if (env.EXPERIMENTALMODE == 'NO') {
                                pushArtifactFolder("deb/", AWS_STASH_PATH)
                            }
                        }
                    }
                }
                stage('Ubuntu Focal(20.04) ARM') {
                    agent {
                        label 'docker-32gb-aarch64'
                    }
                    steps {
                        script {
                            if (env.FIPSMODE == 'YES') {
                                echo "The step is skipped"
                            } else {
                                cleanUpWS()
                                installCli("rpm")
                                unstash 'properties'
                                popArtifactFolder("source_deb/", AWS_STASH_PATH)
                                buildStage("ubuntu:focal", "--build_deb=1 --with_zenfs=1")
                                if (env.EXPERIMENTALMODE == 'NO') {
                                    pushArtifactFolder("deb/", AWS_STASH_PATH)
                                }
                            }
                        }
                    }
                }
                stage('Ubuntu Jammy(22.04) ARM') {
                    agent {
                        label 'docker-32gb-aarch64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("rpm")
                        unstash 'properties'
                        popArtifactFolder("source_deb/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                buildStage("ubuntu:jammy", "--build_deb=1 --with_zenfs=1 --enable_fipsmode=1")
                            } else {
                                buildStage("ubuntu:jammy", "--build_deb=1 --with_zenfs=1")
                            }
                        }

                        pushArtifactFolder("deb/", AWS_STASH_PATH)
                    }
                }
                stage('Ubuntu Noble(24.04) ARM') {
                    agent {
                        label 'docker-32gb-aarch64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("rpm")
                        unstash 'properties'
                        popArtifactFolder("source_deb/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                buildStage("ubuntu:noble", "--build_deb=1 --with_zenfs=1 --enable_fipsmode=1")
                            } else {
                                buildStage("ubuntu:noble", "--build_deb=1 --with_zenfs=1")
                            }
                            if (env.EXPERIMENTALMODE == 'NO') {
                                pushArtifactFolder("deb/", AWS_STASH_PATH)
                            }
                        }
                    }
                }
                stage('Debian Bullseye(11) ARM') {
                    agent {
                        label 'docker-32gb-aarch64'
                    }
                    steps {
                        script {
                            if (env.FIPSMODE == 'YES') {
                                echo "The step is skipped"
                            } else {
                                cleanUpWS()
                                installCli("rpm")
                                unstash 'properties'
                                popArtifactFolder("source_deb/", AWS_STASH_PATH)
                                buildStage("debian:bullseye", "--build_deb=1 --with_zenfs=1")

                                if (env.EXPERIMENTALMODE == 'NO') {
                                    pushArtifactFolder("deb/", AWS_STASH_PATH)
                                }
                            }
                        }
                    }
                }
                stage('Debian Bookworm(12) ARM') {
                    agent {
                        label 'docker-32gb-aarch64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("rpm")
                        unstash 'properties'
                        popArtifactFolder("source_deb/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                buildStage("debian:bookworm", "--build_deb=1 --with_zenfs=1 --enable_fipsmode=1")
                            } else {
                                buildStage("debian:bookworm", "--build_deb=1 --with_zenfs=1")
                            }

                            if (env.EXPERIMENTALMODE == 'NO') {
                                pushArtifactFolder("deb/", AWS_STASH_PATH)
                            }
                        }
                    }
                }
                stage('Oracle Linux 8 binary tarball') {
                    agent {
                        label 'min-ol-8-x64'
                    }
                    steps {
                        script {
                            if (env.FIPSMODE == 'YES') {
                                echo "The step is skipped"
                            } else {
                                cleanUpWS()
                                installCli("rpm")
                                unstash 'properties'
                                popArtifactFolder("source_tarball/", AWS_STASH_PATH)
                                buildStage("none", "--build_tarball=1")
                                if (env.EXPERIMENTALMODE == 'NO') {
                                   pushArtifactFolder("tarball/", AWS_STASH_PATH)
                                }
                            }
                        }
                    }
                }
                stage('Oracle Linux 8 debug tarball') {
                    agent {
                        label 'min-ol-8-x64'
                    }
                    steps {
                        script {
                            if (env.FIPSMODE == 'YES') {
                                echo "The step is skipped"
                            } else {
                                cleanUpWS()
                                installCli("rpm")
                                unstash 'properties'
                                popArtifactFolder("source_tarball/", AWS_STASH_PATH)
                                buildStage("none", "--debug=1 --build_tarball=1")
                                if (env.EXPERIMENTALMODE == 'NO') {
                                   pushArtifactFolder("tarball/", AWS_STASH_PATH)
                                }
                            }
                        }
                    }
                }
                stage('Oracle Linux 9 tarball') {
                    agent {
                        label 'min-ol-9-x64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("rpm")
                        unstash 'properties'
                        popArtifactFolder("source_tarball/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                buildStage("none", "--build_tarball=1 --enable_fipsmode=1")
                            } else {
                                buildStage("none", "--build_tarball=1")
                            }
                            if (env.EXPERIMENTALMODE == 'NO') {
                                pushArtifactFolder("tarball/", AWS_STASH_PATH)
                            }
                        }
                    }
                }
                stage('Oracle Linux 9 ZenFS tarball') {
                    agent {
                        label 'min-ol-9-x64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("rpm")
                        unstash 'properties'
                        popArtifactFolder("source_tarball/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                echo "The step is skipped"
                            } else {
                                buildStage("none", "--build_tarball=1 --with_zenfs=1")
                                if (env.EXPERIMENTALMODE == 'NO') {
                                    pushArtifactFolder("tarball/", AWS_STASH_PATH)
                                }
                            }
                        }
                    }
                }
                stage('Oracle Linux 9 debug tarball') {
                    agent {
                        label 'min-ol-9-x64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("rpm")
                        unstash 'properties'
                        popArtifactFolder("source_tarball/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                buildStage("none", "--debug=1 --build_tarball=1 --enable_fipsmode=1")
                            } else {
                                buildStage("none", "--debug=1 --build_tarball=1")
                            }
                            if (env.EXPERIMENTALMODE == 'NO') {
                                pushArtifactFolder("tarball/", AWS_STASH_PATH)
                            }
                        }
                    }
                }
                stage('Ubuntu Focal(20.04) tarball') {
                    agent {
                        label 'min-focal-x64'
                    }
                    steps {
                        script {
                            if (env.FIPSMODE == 'YES') {
                                echo "The step is skipped"
                            } else {
                                cleanUpWS()
                                installCli("deb")
                                unstash 'properties'
                                popArtifactFolder("source_tarball/", AWS_STASH_PATH)
                                buildStage("none", "--build_tarball=1")
                                if (env.EXPERIMENTALMODE == 'NO') {
                                    pushArtifactFolder("tarball/", AWS_STASH_PATH)
                                }
                            }
                        }
                    }
                }
                stage('Ubuntu Focal(20.04) debug tarball') {
                    agent {
                        label 'min-focal-x64'
                    }
                    steps {
                        script {
                            if (env.FIPSMODE == 'YES') {
                                echo "The step is skipped"
                            } else {
                                cleanUpWS()
                                installCli("deb")
                                unstash 'properties'
                                popArtifactFolder("source_tarball/", AWS_STASH_PATH)
                                buildStage("none", "--debug=1 --build_tarball=1")
                                if (env.EXPERIMENTALMODE == 'NO') {
                                    pushArtifactFolder("tarball/", AWS_STASH_PATH)
                                }
                            }
                        }
                    }
                }
                stage('Ubuntu Jammy(22.04) tarball') {
                    agent {
                        label 'min-jammy-x64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("deb")
                        unstash 'properties'
                        popArtifactFolder("source_tarball/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                buildStage("none", "--build_tarball=1 --enable_fipsmode=1")
                            } else {
                                buildStage("none", "--build_tarball=1")
                            }
                            if (env.EXPERIMENTALMODE == 'NO') {
                                pushArtifactFolder("tarball/", AWS_STASH_PATH)
                            }
                        }
                    }
                }
                stage('Ubuntu Jammy(22.04) ZenFS tarball') {
                    agent {
                        label 'min-jammy-x64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("deb")
                        unstash 'properties'
                        popArtifactFolder("source_tarball/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                echo "The step is skipped"
                            } else {
                                buildStage("none", "--build_tarball=1 --with_zenfs=1")
                                if (env.EXPERIMENTALMODE == 'NO') {
                                   pushArtifactFolder("tarball/", AWS_STASH_PATH)
                                }
                            }
                        }
                    }
                }
                stage('Ubuntu Jammy(22.04) debug tarball') {
                    agent {
                        label 'min-jammy-x64'
                    }
                    steps {
                        cleanUpWS()
                        installCli("deb")
                        unstash 'properties'
                        popArtifactFolder("source_tarball/", AWS_STASH_PATH)
                        script {
                            if (env.FIPSMODE == 'YES') {
                                buildStage("none", "--debug=1 --build_tarball=1 --enable_fipsmode=1")
                            } else {
                                buildStage("none", "--debug=1 --build_tarball=1")
                            }
                            if (env.EXPERIMENTALMODE == 'NO') {
                               pushArtifactFolder("tarball/", AWS_STASH_PATH)
                            }
                        }
                    }
                }
            }
        }
        stage('Upload packages and tarballs from S3') {
            agent {
                label 'min-jammy-x64'
            }
            steps {
                cleanUpWS()
                installCli("deb")
                unstash 'properties'

                uploadRPMfromAWS("rpm/", AWS_STASH_PATH)
                uploadDEBfromAWS("deb/", AWS_STASH_PATH)

                script {
                    if (env.EXPERIMENTALMODE == 'NO') {
                        uploadTarballfromAWS("tarball/", AWS_STASH_PATH, 'binary')
                    }
                }
            }
        }

        stage('Sign packages') {
            steps {
                script {
                    if (env.EXPERIMENTALMODE == 'NO') {
                        signRPM()
                    }
                }
                signDEB()
            }
        }
        stage('Push to public repository') {
            steps {
                unstash 'properties'
                script {
                    MYSQL_VERSION_MINOR = sh(returnStdout: true, script: ''' curl -s -O $(echo ${GIT_REPO} | sed -re 's|github.com|raw.githubusercontent.com|; s|\\.git$||')/${BRANCH}/MYSQL_VERSION; cat MYSQL_VERSION | grep MYSQL_VERSION_MINOR | awk -F= '{print $2}' ''').trim()
                    PS_MAJOR_RELEASE = sh(returnStdout: true, script: ''' echo ${BRANCH} | sed "s/release-//g" | sed "s/\\.//g" | awk '{print substr($0, 0, 2)}' ''').trim()
                    // sync packages
                    if (env.FIPSMODE == 'YES') {
                        if ("${MYSQL_VERSION_MINOR}" == "7") {
                            sync2PrivateProdAutoBuild("ps-97-pro", COMPONENT)
                        } else {
                            sync2PrivateProdAutoBuild("ps-9x-innovation-pro", COMPONENT)
                        }
                    } else {
                        if ("${MYSQL_VERSION_MINOR}" == "7") {
                            sync2ProdAutoBuild("ps-97-lts", COMPONENT)
                        } else {
                            sync2ProdAutoBuild("ps-9x-innovation", COMPONENT)
                        }
                    }
                }
            }
        }
/*
        stage('Push Tarballs to TESTING download area') {
            steps {
                script {
                    try {
                        if (env.FIPSMODE == 'YES') {
                            uploadTarballToDownloadsTesting("ps-gated", "${BRANCH}")
                        } else {
                            uploadTarballToDownloadsTesting("ps", "${BRANCH}")
                        }
                    }
                    catch (err) {
                        echo "Caught: ${err}"
                        currentBuild.result = 'UNSTABLE'
                    }
                }
            }
        }
*/
    }
    post {
        success {
            script {
                if (env.FIPSMODE == 'YES') {
                    slackNotify("${SLACKNOTIFY}", "#00FF00", "[${JOB_NAME}]: PRO build has been finished successfully for ${BRANCH} - [${BUILD_URL}]")
                } else {
                    slackNotify("${SLACKNOTIFY}", "#00FF00", "[${JOB_NAME}]: build has been finished successfully for ${BRANCH} - [${BUILD_URL}]")
                }
            }
            slackNotify("${SLACKNOTIFY}", "#00FF00", "[${JOB_NAME}]: Triggering Builds for Package Testing for ${BRANCH} - [${BUILD_URL}]")
            unstash 'properties'
            script {
                currentBuild.description = "Built on ${BRANCH}; path to packages: ${COMPONENT}/${AWS_STASH_PATH}"
            }
            deleteDir()
        }
        failure {
            slackNotify("${SLACKNOTIFY}", "#FF0000", "[${JOB_NAME}]: build failed for ${BRANCH} - [${BUILD_URL}]")
            script {
                currentBuild.description = "Built on ${BRANCH}"
            }
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
