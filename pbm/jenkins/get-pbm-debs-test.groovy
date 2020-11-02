library changelog: false, identifier: 'lib@PBM_test', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/vorsel/jenkins-pipelines.git'
]) _

def TEST_VAR

pipeline {
    agent {
        label 'docker'
    }
    parameters {
        string(
            defaultValue: 'https://github.com/percona/percona-backup-mongodb.git',
            description: 'URL for percona-mongodb-backup repository',
            name: 'GIT_REPO')
    }
    options {
        skipDefaultCheckout()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10', artifactNumToKeepStr: '10'))
        timestamps ()
    }
    stages {
        stage('Check debs') {
            steps {
                slackNotify("@alex.miroshnychenko", "#00FF00", "[${JOB_NAME}]: build started")
		withCredentials([string(credentialsId: 'SIGN_PASSWORD', variable: 'SIGN_PASSWORD')]) {
		    withCredentials([sshUserPrivateKey(credentialsId: 'repo.ci.percona.com', keyFileVariable: 'KEY_PATH', passphraseVariable: '', usernameVariable: 'USER')]) {
			sh """
                cat /etc/hosts > ./hosts
                echo '10.30.6.9 repo.ci.percona.com' >> ./hosts
                sudo cp ./hosts /etc/
			    ssh -o StrictHostKeyChecking=no -i ${KEY_PATH} ${USER}@repo.ci.percona.com ' \
				set -o errexit
				set -o xtrace
                deb=debian/bionic/x86_64/percona-server-mongodb-36-shell_3.6.20-9.0.bionic_amd64.deb
                pkg_fname=\$(basename \${deb})
#               echo qwe
                echo qwe
                EC=0
                /usr/local/reprepro5/bin/reprepro --list-format '"'"'\${package}_\${version}_\${architecture}.deb\\n'"'"' -Vb /srv/repo-copy/psmdb-36/apt -C testing list bionic | grep \${pkg_fname} > /dev/null || EC=\$?
                TEST_VAR=\$EC
                            '
			"""
		    }

		}
                slackNotify("@alex.miroshnychenko", "#00FF00", "[${JOB_NAME}]: build finished with EC=[${TEST_VAR}]")
            }
        }
    }
    post {
        always {
            sh '''
                sudo rm -rf ./*
            '''
            deleteDir()
        }
    }
}
