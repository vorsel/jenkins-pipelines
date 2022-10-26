library changelog: false, identifier: 'lib@PSMDB-1093_tarballs_to_testing', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/vorsel/jenkins-pipelines.git'
]) _

void cleanUpWS() {
    sh """
        sudo rm -rf ./*
    """
}

def AWS_STASH_PATH

pipeline {
    agent {
        label 'master'
    }
    options {
        skipDefaultCheckout()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10', artifactNumToKeepStr: '10'))
        timestamps ()
    }
    stages {
        stage('Push Tarballs to downloads testing') {
            steps {
                script {
                    try {
                        sh '''
                           echo "UPLOAD/experimental/BUILDS/percona-server-mongodb-6.0/percona-server-mongodb-6.0.2-1/release-6.0.2-1/e227063/26" > uploadPath
                           cat uploadPath
                        '''
                        stash includes: 'uploadPath', name: 'uploadPath'
                        uploadTarballToDownloadsTesting("psmdb", "6.0.2-1-test")
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
            slackNotify("@alex.miroshnychenko", "#00FF00", "[${JOB_NAME}]: build has been finished successfully for GIT_BRANCH - [${BUILD_URL}]")
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
