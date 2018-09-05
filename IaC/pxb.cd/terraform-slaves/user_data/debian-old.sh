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

apt-get -y install git wget
wget https://jenkins.percona.com/downloads/jre/jre-8u152-linux-x64.tar.gz
tar -zxf jre-8u152-linux-x64.tar.gz -C /usr/local
ln -s /usr/local/jre1.8.0_152 /usr/local/java
ln -s /usr/local/jre1.8.0_152/bin/java /usr/bin/java
rm -fv jre-8u152-linux-x64.tar.gz
install -o $(id -u admin || id -u ubuntu) -g $(id -g admin || id -g ubuntu) -d /mnt/jenkins
