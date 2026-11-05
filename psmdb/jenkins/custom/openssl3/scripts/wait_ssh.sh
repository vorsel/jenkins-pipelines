#!/bin/bash
# wait_ssh.sh HOST USER KEYFILE [timeout seconds, default 300]
set -uo pipefail
end=$((SECONDS + ${4:-300}))
while [ $SECONDS -lt $end ]; do
    ssh -i "$3" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 "$2@$1" 'sudo true' 2>/dev/null && exit 0
    sleep 5
done
echo "ssh to $2@$1 not ready after ${4:-300}s" >&2
exit 1
