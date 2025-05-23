library changelog: false, identifier: "lib@master", retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/Percona-Lab/jenkins-pipelines.git'
])

def sendSlackNotification(version)
{
 if ( currentBuild.result == "SUCCESS" ) {
  buildSummary = "Job: ${env.JOB_NAME}\nVersion: ${version}\nStatus: *SUCCESS*\nBuild Report: ${env.BUILD_URL}"
  slackSend color : "good", message: "${buildSummary}", channel: '#postgresql-test'
 }
 else {
  buildSummary = "Job: ${env.JOB_NAME}\nVersion: ${version}\nStatus: *FAILURE*\nBuild number: ${env.BUILD_NUMBER}\nBuild Report :${env.BUILD_URL}"
  slackSend color : "danger", message: "${buildSummary}", channel: '#postgresql-test'
 }
}


pipeline {
  agent {
      label 'min-ol-9-x64'
  }
  parameters {
        choice(
            name: 'SSL_VERSION',
            description: 'SSL version to use',
            choices: [
                '1'
            ]
        )
        string(
            defaultValue: 'ppg-17.5',
            description: 'PG version for test',
            name: 'VERSION'
        )
        string(
            defaultValue: 'https://downloads.percona.com/downloads/TESTING/pg_tarballs-17.0/percona-postgresql-17.0-ssl1.1-linux-x86_64.tar.gz',
            description: 'URL for tarball.',
            name: 'TARBALL_URL'
        )
        string(
            defaultValue: 'Q2-2025',
            description: 'Branch for testing repository',
            name: 'TESTING_BRANCH'
        )
        string(
            defaultValue: 'yes',
            description: 'Destroy VM after tests',
            name: 'DESTROY_ENV'
        )
  }
  environment {
      PATH = '/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/home/ec2-user/.local/bin';
      MOLECULE_DIR = "ppg/pg-tarballs";
  }
  options {
          withCredentials(moleculeDistributionJenkinsCreds())
          disableConcurrentBuilds()
  }
    stages {
        stage('Set build name'){
          steps {
                    script {
                        currentBuild.displayName = "${env.BUILD_NUMBER}-${env.VERSION}-${env.JOB_NAME}"
                    }
                }
            }
        stage('Checkout') {
            steps {
                deleteDir()
                git poll: false, branch: TESTING_BRANCH, url: 'https://github.com/Percona-QA/ppg-testing.git'
            }
        }
        stage ('Prepare') {
          steps {
                script {
                   installMoleculePython39()
             }
           }
        }
        stage('Test') {
          steps {
                script {
                    moleculeParallelTestPPG(ppgOperatingSystemsSSL1(), env.MOLECULE_DIR)
                }
            }
         }
  }
    post {
        always {
          script {
              moleculeParallelPostDestroyPPG(ppgOperatingSystemsSSL1(), env.MOLECULE_DIR)
              sendSlackNotification(env.VERSION)
         }
      }
   }
}
