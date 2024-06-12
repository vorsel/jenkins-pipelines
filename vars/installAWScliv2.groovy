def call() {
    sh '''
        if ! $(aws --version | grep -q 'aws-cli/2'); then
	    find /tmp -maxdepth 1 -name "*aws*" | xargs rm -rf

	    if ! command -v unzip &> /dev/null; then
		if [ -f /usr/bin/rpm ]; then
		    yum install -y unzip wget
		elif [ -f /usr/bin/dpkg ]; then
		    DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y curl wget unzip
		else
		    echo "Unable to install unzip."
		    exit 1
		fi
	    fi

	    until curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "/tmp/awscliv2.zip"; do
		sleep 1
		echo "try again"
	    done

	    unzip -o /tmp/awscliv2.zip -d /tmp
	    cd /tmp/aws && ./install
	fi
    '''
}
