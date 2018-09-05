#!/bin/bash

set -o xtrace

if ! mountpoint -q /mnt; then
    DEVICE=$(ls /dev/xvdd /dev/nvme1n1 | head -1)
    mkfs.ext2 $DEVICE
    mount $DEVICE /mnt
fi
until yum makecache; do
    sleep 1
    echo try again
done

yum -y install java-1.8.0-openjdk git aws-cli || :
yum -y remove java-1.7.0-openjdk || :
install -o centos -g centos -d /mnt/jenkins
