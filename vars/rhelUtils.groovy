@groovy.transform.Field def script
@groovy.transform.Field def dockerUtils

def enableSubscription(String containerName) {
    script.withCredentials([script.usernamePassword(credentialsId: 'rhel.subscription', usernameVariable: 'RHEL_SUBSCRIPTION_USERNAME', passwordVariable: 'RHEL_SUBSCRIPTION_PASSWORD')]) {
        def systemName = "${script.env.JOB_NAME}-${script.env.BUILD_NUMBER}-${containerName}"
        def command = """
            if ! command -v subscription-manager &> /dev/null; then
                echo "subscription-manager could not be found, attempting to install..."
                microdnf install -y subscription-manager || { echo "Failed to install subscription-manager."; exit 1; }
            fi
            subscription-manager register --username='${script.env.RHEL_SUBSCRIPTION_USERNAME}' --password='${script.env.RHEL_SUBSCRIPTION_PASSWORD}' --name='${systemName}' || { echo "Failed to register subscription."; exit 1; }
            subscription-manager release --set=10 || { echo "Failed to set release."; exit 1; }
        """
        dockerUtils.execCommand(containerName, command)
    }
    script.echo "RHEL subscription enabled for container ${containerName}."
}

def disableSubscription(String containerName) {
    def command = """
        if command -v subscription-manager &> /dev/null; then
            echo "Unregistering subscription..."
            subscription-manager unregister || echo "Failed to unregister subscription. Continuing..."
            subscription-manager clean || echo "Failed to clean subscription data. Continuing..."
        else
            echo "subscription-manager not found, skipping unregister."
        fi
    """
    dockerUtils.execCommand(containerName, command)
    script.echo "RHEL subscription disabled for container ${containerName}."
}