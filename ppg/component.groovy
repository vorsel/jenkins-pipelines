library changelog: false, identifier: "lib@master", retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/Percona-Lab/jenkins-pipelines.git'
])

def sendSlackNotification(componentName, ppgVersion, componentVersion)
{
 if ( currentBuild.result == "SUCCESS" ) {
  buildSummary = "Job: ${env.JOB_NAME}\nComponent: ${componentName}\nComponent Version: ${componentVersion}\nPPG Version: ${ppgVersion}\nStatus: *SUCCESS*\nBuild Report: ${env.BUILD_URL}"
  slackSend color : "good", message: "${buildSummary}", channel: '#postgresql-test'
 }
 else {
  buildSummary = "Job: ${env.JOB_NAME}\nComponent: ${componentName}\nComponent Version: ${componentVersion}\nPPG Version: ${ppgVersion}\nStatus: *FAILURE*\nBuild number: ${env.BUILD_NUMBER}\nBuild Report :${env.BUILD_URL}"
  slackSend color : "danger", message: "${buildSummary}", channel: '#postgresql-test'
 }
}

pipeline {
  agent {
  label 'min-ol-9-x64'
  }

  parameters {
        choice(
            name: 'REPO',
            description: 'PPG repo for testing',
            choices: [
                'testing',
                'experimental',
                'release'
            ]
        )
        string(
            defaultValue: 'Q2-2025',
            description: 'Branch for tests',
            name: 'TEST_BRANCH'
         )
        string(
            defaultValue: 'https://github.com/pgaudit/pgaudit.git',
            description: 'Component repo for test',
            name: 'COMPONENT_REPO'
         )
        string(
            defaultValue: 'master',
            description: 'Component version for test',
            name: 'COMPONENT_VERSION'
         )
        string(
            defaultValue: 'ppg-17.5',
            description: 'PPG version for test',
            name: 'VERSION'
         )
        choice(
            name: 'PRODUCT',
            description: 'Product to test',
            choices: ['pg_contrib',
                      'pg_audit',
                      'pg_repack',
                      'patroni',
                      'pgbackrest',
                      'pgpool',
                      'postgis',
                      'pgaudit13_set_user',
                      'pgbadger',
                      'pgbouncer',
                      'wal2json']
            )
        choice(
            name: 'SCENARIO',
            description: 'PPG major version to test',
            choices: ['ppg-11', 'ppg-12', 'ppg-13', 'ppg-14', 'ppg-15', 'ppg-16']
        )
        string(
            defaultValue: 'yes',
            description: 'Destroy VM after tests',
            name: 'DESTROY_ENV'
        )
  }
  environment {
      PATH = '/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/home/ec2-user/.local/bin';
      MOLECULE_DIR = "${PRODUCT}/${SCENARIO}";
  }
  options {
          withCredentials(moleculeDistributionJenkinsCreds())
          disableConcurrentBuilds()
  }
  stages {
    stage('Set build name'){
      steps {
                script {
                    currentBuild.displayName = "${env.SCENARIO}-${env.PRODUCT}-${env.BUILD_NUMBER}"
                }
            }
        }
    stage('Checkout') {
      steps {
            deleteDir()
            git poll: false, branch: env.TEST_BRANCH, url: 'https://github.com/Percona-QA/ppg-testing.git'
        }
    }
    stage ('Prepare') {
      steps {
          script {
              installMoleculePython39()
            }
        }
    }
    stage ('Run tests') {
      steps {
          script{
              moleculeExecuteActionWithScenarioPPG(env.MOLECULE_DIR, "test", "default")
            }
        }
    }
  }
  post {
    always {
          script {
             if (env.DESTROY_ENV == "yes") {
             moleculeExecuteActionWithScenarioPPG(env.MOLECULE_DIR, "destroy", "default")
             }
             sendSlackNotification(env.PRODUCT, env.VERSION, env.COMPONENT_VERSION)
        }
    }
  }
}
