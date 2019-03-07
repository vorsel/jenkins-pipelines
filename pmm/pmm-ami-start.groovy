pipeline {
    agent {
        label 'awscli'
    }
    parameters {
        choice(
            choices: '4\n0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16',
            description: 'Stop the instance after, days ("0" value disables autostop and recreates instance in case of AWS failure)',
            name: 'DAYS')
        string(
            defaultValue: 'dev-latest',
            description: 'PMM Client version',
            name: 'CLIENT_VERSION')
        string(
            defaultValue: '',
            description: 'AMI Image version',
            name: 'AMI_ID')
        string(
            defaultValue: '',
            description: 'public ssh key for "admin" user, please set if you need ssh access',
            name: 'SSH_KEY')
        string(
            defaultValue: '5.7',
            description: 'Percona Server for MySQL version',
            name: 'PS_VERSION')
        string(
            defaultValue: '--addclient=ps,1',
            description: 'Configure PMM Clients. ps - Percona Server for MySQL, pxc - Percona XtraDB Cluster, ms - MySQL Community Server, md - MariaDB Server, MO - Percona Server for MongoDB, pgsql - Postgre SQL Server',
            name: 'CLIENTS')
        string(
            defaultValue: 'false',
            description: 'Enable Slack notification (option for high level pipelines)',
            name: 'NOTIFY')
    }
    options {
        skipDefaultCheckout()
        disableConcurrentBuilds()
    }

    stages {
        stage('Prepare') {
            steps {
                deleteDir()
                withCredentials([usernamePassword(credentialsId: 'Jenkins API', passwordVariable: 'PASS', usernameVariable: 'USER')]) {
      sh """
                        curl -s -u ${USER}:${PASS} ${BUILD_URL}api/json \
                            | python -c "import sys, json; print json.load(sys.stdin)['actions'][1]['causes'][0]['userId']" \
                            | sed -e 's/@percona.com//' \
                            > OWNER
                        echo "pmm-\$(cat OWNER | cut -d . -f 1)-\$(date -u '+%Y%m%d%H%M')" \
                            > VM_NAME
                    """
                }
                script {
                    def OWNER = sh(returnStdout: true, script: "cat OWNER").trim()
                    echo """
                        CLIENT_VERSION: ${CLIENT_VERSION}
                        PS_VERSION:     ${PS_VERSION}
                        MS_VERSION:     ${MS_VERSION}
                        CLIENTS:        ${CLIENTS}
                        OWNER:          ${OWNER}
                    """
                    if ("${NOTIFY}" == "true") {
                        slackSend channel: '#pmm-ci', color: '#FFFF00', message: "[${JOB_NAME}]: build started - ${BUILD_URL}"
                        slackSend channel: "@${OWNER}", color: '#FFFF00', message: "[${JOB_NAME}]: build started - ${BUILD_URL}"
                    }
                }
            }
        }
        
    stage('Run VM with PMM server') { 
      steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', accessKeyVariable: 'AWS_ACCESS_KEY_ID',  credentialsId: 'AMI/OVF', secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                    sh '''
                        export VM_NAME=\$(cat VM_NAME)
                        export OWNER=\$(cat OWNER)
                        export AWS_DEFAULT_REGION=us-east-1
                        
                        export SG1=\$(
                            aws ec2 describe-security-groups \
                                --region us-east-1 \
                                --output text \
                                --filters "Name=group-name,Values=pmm" \
                                --query 'SecurityGroups[].GroupId'
                        )
                        
                        export SS1=\$(
                            aws ec2 describe-subnets \
                                --region us-east-1 \
                                --output text \
                                --query 'Subnets[1].SubnetId'
                        )

                        IMAGE_NAME=$(
                            aws ec2 describe-images \
                            --image-ids $AMI_ID \
                            --query 'Images[].Name' \
                            --output text
                            )
                        echo "IMAGE_NAME:    $IMAGE_NAME"

                        INSTANCE_ID=\$(
                            aws ec2 run-instances \
                            --image-id $AMI_ID \
                            --security-group-ids $SG1 \
                            --instance-type t2.micro \
                            --subnet-id $SS1 \
                            --region us-east-1 \
                            --key-name pmm-qa \
                            --query Instances[].InstanceId \
                            --output text
                        )

                        echo \$INSTANCE_ID > INSTANCE_ID

                        INSTANCE_NAME=nailya-pmm
                            aws ec2 create-tags  \
                            --resources $INSTANCE_ID \
                            --region us-east-1 \
                            --tags Key=Name,Value=$INSTANCE_NAME \
                            Key=iit-billing-tag,Value=qa \
                            Key=stop-after-days,Value=${DAYS}
                           
                        echo "INSTANCE_NAME: $INSTANCE_NAME"
                        
                        

                       IP_PUBLIC=\$(
                              aws ec2 describe-instances \
                              --instance-ids $INSTANCE_ID \
                              --region us-east-1 \
                              --output text \
                              --query 'Reservations[].Instances[].PublicIpAddress' \
                             | tee IP
                             )
                        
                        echo \$IP_PUBLIC > IP_PUBLIC
                         

                         IP_PRIVATE=\$(
                            aws ec2 describe-instances \
                              --instance-ids $INSTANCE_ID \
                              --region us-east-1 \
                              --output text \
                              --query 'Reservations[].Instances[].PrivateIpAddress' \
                             | tee IP
                             )

                        echo \$IP_PRIVATE > IP_PRIVATE
                    '''
                }
                 
                script {
                    env.IP_PRIVATE  = sh(returnStdout: true, script: "cat IP_PRIVATE").trim()
                    env.IP  = sh(returnStdout: true, script: "cat IP_PUBLIC").trim()
                    env.INSTANCE_ID  = sh(returnStdout: true, script: "cat INSTANCE_ID").trim()
                    env.VM_NAME = sh(returnStdout: true, script: "cat VM_NAME").trim()
                     }
          archiveArtifacts 'IP'  
          archiveArtifacts 'INSTANCE_ID' 
          
          }
            
        }
    

    stage('Run VM with MySQL server') { 
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', accessKeyVariable: 'AWS_ACCESS_KEY_ID',  credentialsId: 'AMI/OVF', secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                sh '''
                    export VM_NAME=\$(cat VM_NAME)
                    export OWNER=\$(cat OWNER)
                    export AWS_DEFAULT_REGION=us-east-1
                    
                    export SG1=\$(
                        aws ec2 describe-security-groups \
                            --region us-east-1 \
                            --output text \
                            --filters "Name=group-name,Values=pmm" \
                            --query 'SecurityGroups[].GroupId'
                        )
                        
                    export SS1=\$(
                        aws ec2 describe-subnets \
                            --region us-east-1 \
                            --output text \
                            --query 'Subnets[1].SubnetId'
                        )
                
                    IMAGE_LINE=$(
                        aws ec2 describe-images \
                        --owners self \
                        --filters "Name=name,Values=Percona Server for MySQL 5.7*" \
                        --query 'Images[].{ImageId:ImageId,Name:Name}' \
                        --output text \
                        | sort -k 4 \
                        | tail -1
                     )
                     
                    IMAGE_ID=$(echo $IMAGE_LINE | awk '{print$1}')

                    IMAGE_NAME=$(
                        aws ec2 describe-images \
                        --image-ids $IMAGE_ID \
                        --query 'Images[].Name' \
                        --output text
                    )
                    echo "IMAGE_NAME:    $IMAGE_NAME"

                    INSTANCE_ID_CLIENT=\$(
                        aws ec2 run-instances \
                        --image-id $IMAGE_ID \
                        --security-group-ids $SG1 \
                        --instance-type t2.micro \
                        --subnet-id $SS1 \
                        --region us-east-1 \
                        --key-name pmm-qa \
                        --query Instances[].InstanceId \
                        --output text
                    )
                    echo \$INSTANCE_ID_CLIENT > INSTANCE_ID_CLIENT

                    INSTANCE_NAME=nailya-mysql
                        aws ec2 create-tags  \
                        --resources $INSTANCE_ID_CLIENT \
                        --region us-east-1 \
                        --tags Key=Name,Value=$INSTANCE_NAME \
                         Key=iit-billing-tag,Value=qa
                    echo "INSTANCE_NAME: $INSTANCE_NAME"
                    
                     until [ -s IP ]; do
                        sleep 1
                            aws ec2 describe-instances \
                            --instance-ids $INSTANCE_ID_CLIENT \
                            --region us-east-1 \
                            --output text \
                            --query 'Reservations[].Instances[].PublicIpAddress' \
                        | tee IP
                        done
                     echo \$IP > IP_CLIENT
            '''
            }
                            
                script {
                    env.IP_CLIENT  = sh(returnStdout: true, script: "cat IP_CLIENT").trim()
                    env.INSTANCE_ID_CLIENT  = sh(returnStdout: true, script: "cat INSTANCE_ID_CLIENT").trim()
                    env.VM_NAME = sh(returnStdout: true, script: "cat VM_NAME").trim()
                     }
          archiveArtifacts 'IP_CLIENT'  
          archiveArtifacts 'INSTANCE_ID_CLIENT' 
          
        }
    }
  
    }  

    post {
        success {
            script {
                if ("${NOTIFY}" == "true") {
                    def OWNER = sh(returnStdout: true, script: "cat OWNER").trim()

                    slackSend channel: '#pmm-ci', color: '#00FF00', message: "[${JOB_NAME}]: build finished, owner: @${OWNER} - https://${IP} Instance ID: ${INSTANCE_ID} MySQL client: ${IP_CLIENT}, ${INSTANCE_ID_CLIENT}"
                    slackSend channel: "@${OWNER}", color: '#00FF00', message: "[${JOB_NAME}]: build finished - https://${IP} Instance ID: ${INSTANCE_ID}"
                }
            }
        }
        failure {
                 withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', accessKeyVariable: 'AWS_ACCESS_KEY_ID', credentialsId: 'AMI/OVF', secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                sh '''
                    export INSTANCE_ID=\$(cat INSTANCE_ID)
                    export INSTANCE_ID_CLIENT=\$(cat INSTANCE_ID_CLIENT)
                    
                    if [ -n "$INSTANCE_ID" ]; then
                      aws ec2 --region us-east-1 terminate-instances --instance-ids \$INSTANCE_ID
                    fi
                    if [ -n "$INSTANCE_ID_CLIENT" ]; then
                      aws ec2 --region us-east-1 terminate-instances --instance-ids \$INSTANCE_ID_CLIENT
                    fi
                '''
            }
            script {
                if ("${NOTIFY}" == "false") {
                    def OWNER = sh(returnStdout: true, script: "cat OWNER").trim()

                    slackSend channel: '#pmm-ci', color: '#FF0000', message: "[${JOB_NAME}]: build failed, owner: @${OWNER}"
                    slackSend channel: "@${OWNER}", color: '#FF0000', message: "[${JOB_NAME}]: build failed"
                }
            }
        }
    }
}

