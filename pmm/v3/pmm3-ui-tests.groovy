library changelog: false, identifier: 'lib@master', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/Percona-Lab/jenkins-pipelines.git'
]) _

library changelog: false, identifier: 'v3lib@master', retriever: modernSCM(
  scm: [$class: 'GitSCMSource', remote: 'https://github.com/Percona-Lab/jenkins-pipelines.git'],
  libraryPath: 'pmm/v3/'
)

pipeline {
    agent {
        label 'agent-amd64-ol9'
    }
    environment {
        AZURE_CLIENT_ID=credentials('AZURE_CLIENT_ID');
        AZURE_CLIENT_SECRET=credentials('AZURE_CLIENT_SECRET');
        AZURE_MYSQL_HOST=credentials('AZURE_MYSQL_HOST');
        AZURE_MYSQL_PASS=credentials('AZURE_MYSQL_PASS');
        AZURE_MYSQL_USER=credentials('AZURE_MYSQL_USER');
        AZURE_POSTGRES_HOST=credentials('AZURE_POSTGRES_HOST');
        AZURE_POSTGRES_PASS=credentials('AZURE_POSTGRES_PASS');
        AZURE_POSTGRES_USER=credentials('AZURE_POSTGRES_USER');
        AZURE_SUBSCRIPTION_ID=credentials('AZURE_SUBSCRIPTION_ID');
        AZURE_TENNANT_ID=credentials('AZURE_TENNANT_ID');
        GCP_SERVER_IP=credentials('GCP_SERVER_IP');
        GCP_USER=credentials('GCP_USER');
        GCP_USER_PASSWORD=credentials('GCP_USER_PASSWORD');
        GCP_MYSQL57_HOST=credentials('GCP_MYSQL57_HOST');
        GCP_MYSQL57_USER=credentials('GCP_MYSQL57_USER');
        GCP_MYSQL57_PASSWORD=credentials('GCP_MYSQL57_PASSWORD');
        GCP_MYSQL80_HOST=credentials('GCP_MYSQL80_HOST');
        GCP_MYSQL80_USER=credentials('GCP_MYSQL80_USER');
        GCP_MYSQL80_PASSWORD=credentials('GCP_MYSQL80_PASSWORD');
        GCP_MYSQL84_HOST=credentials('GCP_MYSQL84_HOST');
        GCP_MYSQL84_USER=credentials('GCP_MYSQL84_USER');
        GCP_MYSQL84_PASSWORD=credentials('GCP_MYSQL84_PASSWORD');
        GCP_PGSQL13_HOST=credentials('GCP_PGSQL13_HOST');
        GCP_PGSQL13_USER=credentials('GCP_PGSQL13_USER');
        GCP_PGSQL13_PASSWORD=credentials('GCP_PGSQL13_PASSWORD');
        GCP_PGSQL14_HOST=credentials('GCP_PGSQL14_HOST');
        GCP_PGSQL14_USER=credentials('GCP_PGSQL14_USER');
        GCP_PGSQL14_PASSWORD=credentials('GCP_PGSQL14_PASSWORD');
        GCP_PGSQL15_HOST=credentials('GCP_PGSQL15_HOST');
        GCP_PGSQL15_USER=credentials('GCP_PGSQL15_USER');
        GCP_PGSQL15_PASSWORD=credentials('GCP_PGSQL15_PASSWORD');
        GCP_PGSQL16_HOST=credentials('GCP_PGSQL16_HOST');
        GCP_PGSQL16_USER=credentials('GCP_PGSQL16_USER');
        GCP_PGSQL16_PASSWORD=credentials('GCP_PGSQL16_PASSWORD');
        GCP_PGSQL17_HOST=credentials('GCP_PGSQL17_HOST');
        GCP_PGSQL17_USER=credentials('GCP_PGSQL17_USER');
        GCP_PGSQL17_PASSWORD=credentials('GCP_PGSQL17_PASSWORD');
        REMOTE_AWS_MYSQL_USER=credentials('pmm-dev-mysql-remote-user')
        REMOTE_AWS_MYSQL_PASSWORD=credentials('pmm-dev-remote-password')
        REMOTE_AWS_MYSQL57_HOST=credentials('pmm-dev-mysql57-remote-host')
        REMOTE_AWS_MYSQL80_HOST=credentials('REMOTE_AWS_MYSQL80_HOST')
        REMOTE_AWS_MYSQL80_USER=credentials('REMOTE_AWS_MYSQL80_USER')
        REMOTE_AWS_MYSQL80_PASSWORD=credentials('REMOTE_AWS_MYSQL80_PASSWORD')
        PMM_QA_MYSQL_RDS_8_4_HOST=credentials('PMM_QA_MYSQL_RDS_8_4_HOST')
        PMM_QA_MYSQL_RDS_8_4_USER=credentials('PMM_QA_MYSQL_RDS_8_4_USER')
        PMM_QA_MYSQL_RDS_8_4_PASSWORD=credentials('PMM_QA_MYSQL_RDS_8_4_PASSWORD')
        PMM_QA_RDS_PGSQL13_HOST=credentials('PMM_QA_RDS_PGSQL13_HOST')
        PMM_QA_RDS_PGSQL13_USER=credentials('PMM_QA_RDS_PGSQL13_USER')
        PMM_QA_RDS_PGSQL13_PASSWORD=credentials('PMM_QA_RDS_PGSQL13_PASSWORD')
        PMM_QA_RDS_PGSQL14_HOST=credentials('PMM_QA_RDS_PGSQL14_HOST')
        PMM_QA_RDS_PGSQL14_USER=credentials('PMM_QA_RDS_PGSQL14_USER')
        PMM_QA_RDS_PGSQL14_PASSWORD=credentials('PMM_QA_RDS_PGSQL14_PASSWORD')
        PMM_QA_RDS_PGSQL15_HOST=credentials('PMM_QA_RDS_PGSQL15_HOST')
        PMM_QA_RDS_PGSQL15_USER=credentials('PMM_QA_RDS_PGSQL15_USER')
        PMM_QA_RDS_PGSQL15_PASSWORD=credentials('PMM_QA_RDS_PGSQL15_PASSWORD')
        PMM_QA_RDS_PGSQL16_HOST=credentials('PMM_QA_RDS_PGSQL16_HOST')
        PMM_QA_RDS_PGSQL16_USER=credentials('PMM_QA_RDS_PGSQL16_USER')
        PMM_QA_RDS_PGSQL16_PASSWORD=credentials('PMM_QA_RDS_PGSQL16_PASSWORD')
        PMM_QA_RDS_PGSQL17_HOST=credentials('PMM_QA_RDS_PGSQL17_HOST')
        PMM_QA_RDS_PGSQL17_USER=credentials('PMM_QA_RDS_PGSQL17_USER')
        PMM_QA_RDS_PGSQL17_PASSWORD=credentials('PMM_QA_RDS_PGSQL17_PASSWORD')
        REMOTE_MYSQL_HOST=credentials('mysql-remote-host')
        REMOTE_MYSQL_USER=credentials('mysql-remote-user')
        REMOTE_MYSQL_PASSWORD=credentials('mysql-remote-password')
        REMOTE_MONGODB_HOST=credentials('qa-remote-mongodb-host')
        REMOTE_MONGODB_USER=credentials('qa-remote-mongodb-user')
        REMOTE_MONGODB_PASSWORD=credentials('qa-remote-mongodb-password')
        REMOTE_POSTGRESQL_HOST=credentials('qa-remote-pgsql-host')
        REMOTE_POSTGRESQL_USER=credentials('qa-remote-pgsql-user')
        REMOTE_POSTGRESSQL_PASSWORD=credentials('qa-remote-pgsql-password')
        REMOTE_PROXYSQL_HOST=credentials('qa-remote-proxysql-host')
        REMOTE_PROXYSQL_USER=credentials('qa-remote-proxysql-user')
        REMOTE_PROXYSQL_PASSWORD=credentials('qa-remote-proxysql-password')
        INFLUXDB_ADMIN_USER=credentials('influxdb-admin-user')
        INFLUXDB_ADMIN_PASSWORD=credentials('influxdb-admin-password')
        INFLUXDB_USER=credentials('influxdb-user')
        INFLUXDB_USER_PASSWORD=credentials('influxdb-user-password')
        MONITORING_HOST=credentials('monitoring-host')
        EXTERNAL_EXPORTER_PORT=credentials('external-exporter-port')
        MAILOSAUR_API_KEY=credentials('MAILOSAUR_API_KEY')
        MAILOSAUR_SERVER_ID=credentials('MAILOSAUR_SERVER_ID')
        MAILOSAUR_SMTP_PASSWORD=credentials('MAILOSAUR_SMTP_PASSWORD')
        PORTAL_USER_EMAIL=credentials('PORTAL_USER_EMAIL')
        PORTAL_USER_PASSWORD=credentials('PORTAL_USER_PASSWORD')
        OKTA_TOKEN=credentials('OKTA_TOKEN')
        SERVICENOW_LOGIN=credentials('SERVICENOW_LOGIN')
        SERVICENOW_PASSWORD=credentials('SERVICENOW_PASSWORD')
        SERVICENOW_DEV_URL=credentials('SERVICENOW_DEV_URL')
        OAUTH_DEV_CLIENT_ID=credentials('OAUTH_DEV_CLIENT_ID')
        PORTAL_BASE_URL=credentials('PORTAL_BASE_URL')
        PAGER_DUTY_SERVICE_KEY=credentials('PAGER_DUTY_SERVICE_KEY')
        PAGER_DUTY_API_KEY=credentials('PAGER_DUTY_API_KEY')
        PMM_QA_AURORA2_MYSQL_HOST=credentials('PMM_QA_AURORA2_MYSQL_HOST')
        PMM_QA_AURORA2_MYSQL_PASSWORD=credentials('PMM_QA_AURORA2_MYSQL_PASSWORD')
        PMM_QA_AURORA3_MYSQL_HOST=credentials('PMM_QA_AURORA3_MYSQL_HOST')
        PMM_QA_AURORA3_MYSQL_PASSWORD=credentials('PMM_QA_AURORA3_MYSQL_PASSWORD')
        PMM_QA_RDS_AURORA_PGSQL15_HOST=credentials('PMM_QA_RDS_AURORA_PGSQL15_HOST')
        PMM_QA_RDS_AURORA_PGSQL15_USER=credentials('PMM_QA_RDS_AURORA_PGSQL15_USER')
        PMM_QA_RDS_AURORA_PGSQL15_PASSWORD=credentials('PMM_QA_RDS_AURORA_PGSQL15_PASSWORD')
        PMM_QA_RDS_AURORA_PGSQL16_HOST=credentials('PMM_QA_RDS_AURORA_PGSQL16_HOST')
        PMM_QA_RDS_AURORA_PGSQL16_USER=credentials('PMM_QA_RDS_AURORA_PGSQL16_USER')
        PMM_QA_RDS_AURORA_PGSQL16_PASSWORD=credentials('PMM_QA_RDS_AURORA_PGSQL16_PASSWORD')
        PMM_QA_AWS_ACCESS_KEY_ID=credentials('PMM_QA_AWS_ACCESS_KEY_ID')
        PMM_QA_AWS_ACCESS_KEY=credentials('PMM_QA_AWS_ACCESS_KEY')
        ZEPHYR_PMM_API_KEY=credentials('ZEPHYR_PMM_API_KEY')
    }
    parameters {
        string(
            defaultValue: 'v3',
            description: 'Tag/Branch for pmm-ui-tests repository',
            name: 'GIT_BRANCH')
        string(
            defaultValue: '',
            description: 'Commit hash for the branch',
            name: 'GIT_COMMIT_HASH')
        string(
            defaultValue: 'perconalab/pmm-server:3-dev-latest',
            description: 'PMM Server docker container version (image-name:version-tag)',
            name: 'DOCKER_VERSION')
        string(
            defaultValue: '3-dev-latest',
            description: 'PMM Client version',
            name: 'CLIENT_VERSION')
        string(
            defaultValue: '@bm-mongo',
            description: "Run Tests for Specific Areas or cloud providers example: @gcp|@aws|@instances",
            name: 'TAG')
        choice(
            choices: ['no', 'yes'],
            description: 'Enable Pull Mode, if you are using this instance as Client Node',
            name: 'ENABLE_PULL_MODE')
        string(
            defaultValue: 'percona:5.7',
            description: 'Percona Server Docker Container Image',
            name: 'MYSQL_IMAGE')
        string(
            defaultValue: 'perconalab/percona-distribution-postgresql:16.1',
            description: 'Postgresql Docker Container Image',
            name: 'POSTGRES_IMAGE')
        string(
            defaultValue: 'percona/percona-server-mongodb:4.4',
            description: 'Percona Server MongoDb Docker Container Image',
            name: 'MONGO_IMAGE')
        string(
            defaultValue: 'proxysql/proxysql:2.3.0',
            description: 'ProxySQL Docker Container Image',
            name: 'PROXYSQL_IMAGE')
        string(
            defaultValue: 'v3',
            description: 'Tag/Branch for qa-integration repository',
            name: 'PMM_QA_GIT_BRANCH')
        text(
            defaultValue: '--database psmdb,COMPOSE_PROFILES=extra',
            description: '''
            Configure PMM Clients:
            --database ps - Percona Server for MySQL (ex: --database ps=5.7,QUERY_SOURCE=perfschema)
            Additional options:
                QUERY_SOURCE=perfschema|slowlog
                SETUP_TYPE=replica(Replication)|gr(Group Replication)|(single node if no option passed)
            --database mysql - Official MySQL (ex: --database mysql,QUERY_SOURCE=perfschema)
            Additional options:
                QUERY_SOURCE=perfschema|slowlog
            --database psmdb - Percona Server for MongoDB (ex: --database psmdb=latest,SETUP_TYPE=pss)
            Additional options:
                SETUP_TYPE=pss(Primary-Secondary-Secondary)|psa(Primary-Secondary-Arbiter)|shards(Sharded cluster)
            --database pdpgsql - Percona Distribution for PostgreSQL (ex: --database pdpgsql=16)
            --database pgsql - Official PostgreSQL Distribution (ex: --database pgsql=16)
            --database pxc - Percona XtraDB Cluster, (to be used with proxysql only, ex: --database pxc)
            -----
            Example: --database ps=5.7,QUERY_SOURCE=perfschema --database psmdb,SETUP_TYPE=pss
            ''',
            name: 'CLIENTS')
    }
    options {
        skipDefaultCheckout()
    }
    stages {
        stage('Prepare') {
            steps {
                script {
                    env.ADMIN_PASSWORD = "adminV3"
                    if (env.TAG != "") {
                        currentBuild.description = env.TAG
                    }
                    env.PMM_REPO="experimental"
                    if (env.CLIENT_VERSION == "pmm3-rc") {
                        env.PMM_REPO="testing"
                    }
                }
                // clean up workspace and fetch pmm-ui-tests repository
                deleteDir()
                git poll: false,
                    branch: GIT_BRANCH,
                    url: 'https://github.com/percona/pmm-ui-tests.git'

                sh '''
                    sudo ln -s /usr/bin/chromium-browser /usr/bin/chromium
                '''
            }
        }
        stage('Checkout Commit') {
            when {
                expression { env.GIT_COMMIT_HASH.length()>0 }
            }
            steps {
                sh 'git checkout ' + env.GIT_COMMIT_HASH
            }
        }
        stage('Setup PMM Server') {
            parallel {
                stage('Setup Server Instance') {
                    steps {
                        withCredentials([aws(accessKeyVariable: 'AWS_ACCESS_KEY_ID', credentialsId: 'AMI/OVF', secretKeyVariable: 'AWS_SECRET_ACCESS_KEY')]) {
                            sh """
                                docker network create pmm-qa || true
                                aws ecr-public get-login-password --region us-east-1 | docker login -u AWS --password-stdin public.ecr.aws/e7j3v3n0
                                PWD=\$(pwd) MONGO_IMAGE=\${MONGO_IMAGE} POSTGRES_IMAGE=\${POSTGRES_IMAGE} PROXYSQL_IMAGE=\${PROXYSQL_IMAGE} PMM_SERVER_IMAGE=\${DOCKER_VERSION} docker-compose up -d
                                docker network connect pmm-qa pmm-server || true
                            """
                        }
                        waitForContainer('pmm-server', 'pmm-managed entered RUNNING state')
                        waitForContainer('pmm-agent_mongo', 'waiting for connections on port 27017')
                        waitForContainer('pmm-agent_mysql_5_7', "Server hostname (bind-address):")
                        waitForContainer('pmm-agent_postgres', 'PostgreSQL init process complete; ready for start up.')
                        sh '''
                            docker exec pmm-server change-admin-password ${ADMIN_PASSWORD}
                        '''
                        sh '''
                            bash -x testdata/db_setup.sh
                        '''
                        script {
                            env.SERVER_IP = "127.0.0.1"
                            env.PMM_UI_URL = "http://${env.SERVER_IP}/"
                            env.PMM_URL = "http://admin:${env.ADMIN_PASSWORD}@${env.SERVER_IP}"
                        }
                    }
                }
            }
        }
        stage('Setup Clients for PMM-Server') {
            steps {
                 sh '''
                   echo "started client setup"
                 '''
                 setupPMM3Client(SERVER_IP, CLIENT_VERSION.trim(), 'pmm', ENABLE_PULL_MODE, 'no', 'no', 'compose_setup', ADMIN_PASSWORD, 'no')
                 sh '''
                   echo "installed local client"
                 '''
                script {
                        env.PMM_REPO = params.CLIENT_VERSION == "pmm3-rc" ? "testing" : "experimental"
                }
                sh '''
                        set -o errexit
                        set -o xtrace
                        # Exit if no CLIENTS are provided
                        [ -z "${CLIENTS// }" ] && exit 0

                        export PATH=$PATH:/usr/sbin
                        export PMM_CLIENT_VERSION=${CLIENT_VERSION}
                        if [ "${CLIENT_VERSION}" = 3-dev-latest ]; then
                            export PMM_CLIENT_VERSION="3-dev-latest"
                        fi

                        sudo mkdir -p /srv/qa-integration || :
                        pushd /srv/qa-integration
                            sudo git clone --single-branch --branch ${PMM_QA_GIT_BRANCH} https://github.com/Percona-Lab/qa-integration.git .
                        popd

                        sudo chown ec2-user -R /srv/qa-integration

                        pushd /srv/qa-integration/pmm_qa
                            echo "Setting docker based PMM clients"
                            python3 -m venv virtenv
                            . virtenv/bin/activate
                            pip install --upgrade pip
                            pip install -r requirements.txt

                            python pmm-framework.py --v \
                                --pmm-server-password=${ADMIN_PASSWORD} \
                                --client-version=${PMM_CLIENT_VERSION} \
                                ${CLIENTS}
                        popd
                    '''
            }
        }
        stage('Setup') {
            parallel {
                stage('Connectivity check') {
                    steps {
                        sh '''
                            if ! timeout 100 bash -c "until curl -sf ${PMM_URL}/ping; do sleep 1; done"; then
                                echo "PMM Server did not pass the connectivity check" >&2
                                exit 1
                            fi
                          '''
                    }
                }
                stage('Setup Node') {
                    steps {
                        sh """
                            npm ci
                            envsubst < env.list > env.generated.list
                        """
                    }
                }
            }
        }
        stage('Run UI Tests Tagged') {
            options {
                timeout(time: 60, unit: "MINUTES")
            }
            steps {
                script {
                    env.CODECEPT_TAG = "'" + "${TAG}" + "'"
                }
                withCredentials([aws(accessKeyVariable: 'BACKUP_LOCATION_ACCESS_KEY', credentialsId: 'BACKUP_E2E_TESTS', secretKeyVariable: 'BACKUP_LOCATION_SECRET_KEY'), aws(accessKeyVariable: 'AWS_ACCESS_KEY_ID', credentialsId: 'PMM_AWS_DEV', secretKeyVariable: 'AWS_SECRET_ACCESS_KEY')]) {
                    sh """
                        sed -i 's+http://localhost/+${PMM_UI_URL}/+g' pr.codecept.js
                        export PWD=\$(pwd);
                        export PATH=\$PATH:/usr/sbin
                        if [[ \$CLIENT_VERSION != 3-dev-latest ]]; then
                           export PATH="`pwd`/pmm-client/bin:$PATH"
                        fi
                        export CHROMIUM_PATH=/usr/bin/chromium
                        ./node_modules/.bin/codeceptjs run --reporter mocha-multi -c pr.codecept.js --grep ${CODECEPT_TAG}
                    """
                }
            }
        }
    }
    post {
        always {
            // stop staging
            sh '''
                curl --insecure ${PMM_URL}/logs.zip --output logs.zip || true
                echo --- Jobs from pmm-server --- >> job_logs.txt
                docker exec pmm-server psql -Upmm-managed -c 'select id,error,data,created_at,updated_at from jobs ORDER BY updated_at DESC LIMIT 1000;' >> job_logs.txt || true
                echo --- Job logs from pmm-server --- >> job_logs.txt
                docker exec pmm-server psql -Upmm-managed -c 'select * from job_logs ORDER BY job_id LIMIT 1000;' >> job_logs.txt || true
                echo --- pmm-managed logs from pmm-server --- >> pmm-managed-full.log
                docker exec pmm-server cat /srv/logs/pmm-managed.log > pmm-managed-full.log || true
                echo --- pmm-agent logs from pmm-server --- >> pmm-agent-full.log
                docker exec pmm-server cat /srv/logs/pmm-agent.log > pmm-agent-full.log || true
                docker stop webhookd || true
                docker rm webhookd || true
                docker-compose down || true
                docker rm -f $(sudo docker ps -a -q) || true
                docker volume rm $(sudo docker volume ls -q) || true
                sudo chown -R ec2-user:ec2-user . || true
            '''
            script {
                env.PATH_TO_REPORT_RESULTS = 'tests/output/*.xml'
                archiveArtifacts artifacts: 'pmm-managed-full.log'
                archiveArtifacts artifacts: 'pmm-agent-full.log'
                archiveArtifacts artifacts: 'logs.zip'
                archiveArtifacts artifacts: 'job_logs.txt'
                try {
                    junit env.PATH_TO_REPORT_RESULTS
                } catch (err) {
                    error "No test report files found at path: ${PATH_TO_REPORT_RESULTS}"
                }
            }
            /*
            allure([
                includeProperties: false,
                jdk: '',
                properties: [],
                reportBuildPolicy: 'ALWAYS',
                results: [[path: 'tests/output/allure']]
            ])
            */
        }
        failure {
            script {
                archiveArtifacts artifacts: 'tests/output/*.png'
                slackSend botUser: true, channel: '#pmm-notifications', color: '#FF0000', message: "[${JOB_NAME}]: build ${currentBuild.result}, URL: ${BUILD_URL}"
            }
        }
    }
}
