@groovy.transform.Field def script

def startContainer(String containerName, String dockerImage, String dockerRunArgs = "") {
    script.sh """
        docker stop ${containerName} || true
        docker rm ${containerName} || true
        docker run -d -u root --name ${containerName} ${dockerRunArgs} ${dockerImage} sleep infinity
    """
}

def stopContainer(String containerName) {
    script.sh """
        docker stop ${containerName} || true
        docker rm ${containerName} || true
    """
}

def execCommand(String containerName, String command, String workingDir = null, String user = "root") {
    def execOptions = "-u ${user}"
    if (workingDir) {
        execOptions += " -w ${workingDir}"
    }
    script.sh "docker exec ${execOptions} ${containerName} /bin/bash -c '${command}'"
}