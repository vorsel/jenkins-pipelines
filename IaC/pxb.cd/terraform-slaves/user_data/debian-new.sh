#!/bin/bash

set -o xtrace

if ! mountpoint -q /mnt; then
    DEVICE=$(ls /dev/xvdd /dev/nvme1n1 | head -1)
    mkfs.ext2 $DEVICE
    mount $DEVICE /mnt
fi
until apt-get update; do
    sleep 1
    echo try again
done

apt-get -y install openjdk-8-jre-headless git
install -o $(id -u admin || id -u ubuntu) -g $(id -g admin || id -g ubuntu) -d /mnt/jenkins
