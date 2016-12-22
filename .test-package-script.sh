#!/bin/bash

set -o errexit

if [ -z "$1" ]; then
  echo "Specify a Kong installation file"
  exit 1
elif [ ! -f $1 ]; then
    echo "File not found!"
fi

PACKAGE_FILE=$1

if [ "$(uname)" = "Darwin" ]; then
  sudo /usr/sbin/installer -pkg $PACKAGE_FILE -target /
elif hash yum 2>/dev/null; then
  yum install -y epel-release
  yum install -y $PACKAGE_FILE --nogpgcheck
elif hash apt-get 2>/dev/null; then
  apt-get update
  dpkg -i $PACKAGE_FILE || apt-get -y --force-yes install -f
else
  echo "Unsupported platform"
  exit 1
fi

export PATH=$PATH:/usr/local/bin

if ! hash kong; then
  echo "Can't find kong"
  exit 1
fi

# Trying Kong version
kong version
if [ $? -ne 0 ]; then
  exit 1
fi

export KONG_PG_HOST=kong-distributions-test.cyvnqxz6izox.us-east-1.rds.amazonaws.com 
export KONG_PG_PORT=5432 
export KONG_PG_USER=kong 
export KONG_PG_PASSWORD=kongpassword 

kong start --vv
if [ $? -ne 0 ]; then
  exit 1
fi

kong health
if [ $? -ne 0 ]; then
  exit 1
fi

# Install curl later to make sure the default dependencies are enough to start kong
if hash yum 2>/dev/null; then
  yum install -y curl
elif hash apt-get 2>/dev/null; then
  apt-get -y --force-yes install curl
  apt-get install --reinstall procps
fi

if ! [ `curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8001/` == "200" ]; then
  echo "Can't invoke admin API"
  exit 1
fi

if ! [ `curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8001/cluster/` == "200" ]; then
  echo "Can't invoke cluster endpoint on admin API"
  exit 1
fi

RANDOM_API_NAME=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1`
RESPONSE=`curl -s -o /dev/null -w "%{http_code}" -d "name=$RANDOM_API_NAME&request_host=$RANDOM_API_NAME.com&upstream_url=http://mockbin.org/" http://127.0.0.1:8001/apis/`
if ! [ $RESPONSE == "201" ]; then
  echo "Can't create API"
  cat /usr/local/kong/logs/error.log
  exit 1
fi

RESPONSE=`curl -s -o /dev/null -w "%{http_code}" -H "Host: $RANDOM_API_NAME.com" http://127.0.0.1:8000/request`
if ! [ $RESPONSE == "200" ]; then
  echo "Can't invoke API on HTTP"
  cat /usr/local/kong/logs/error.log
  exit 1
fi

RESPONSE=`curl -s -o /dev/null -w "%{http_code}" -H "Host: $RANDOM_API_NAME.com" https://127.0.0.1:8443/request --insecure`
if ! [ $RESPONSE == "200" ]; then
  echo "Can't invoke API on HTTPS"
  cat /usr/local/kong/logs/error.log
  exit 1
fi

kong stop --vv
if [ $? -ne 0 ]; then
  exit 1
fi

echo "Test success!"
exit 0
