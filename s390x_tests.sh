#!/usr/bin/env bash
export SOURCE_ROOT=`pwd`
sudo apt-get install -y wget tar make
wget https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/Go/1.15/build_go.sh
bash build_go.sh -y

sudo apt-get install -y docker.io
sleep 30s
sudo nohup dockerd &
sudo chmod ugo+rw /var/run/docker.sock

docker ps

docker run hello-world

export GOPATH=$SOURCE_ROOT/go
mkdir -p $SOURCE_ROOT/go/src/github.com/moby
cd $SOURCE_ROOT/go/src/github.com/moby
git clone https://github.com/moby/moby
cd moby
git checkout tags/v20.10.6

make test-unit
