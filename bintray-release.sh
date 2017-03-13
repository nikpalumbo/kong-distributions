#!/bin/bash

set -o errexit

##############################################################
#                      Parse Arguments                       #
##############################################################

function usage {
cat << EOF
usage: $0 options

This script release Kong in different distributions

OPTIONS:
 -v      Kong version to release
 -p      Platforms to target
 -u      Bintray Username
 -k      Bintray Key
EOF
}

ARG_PLATFORMS=
KONG_VERSION=
BINTRAY_USERNAME=
BINTRAY_KEY=
while getopts “v:p:u:k:” OPTION
do
  case $OPTION in
    v)
      KONG_VERSION=$OPTARG
      ;;
    p)
      ARG_PLATFORMS=$OPTARG
      ;;
    u)
      BINTRAY_USERNAME=$OPTARG
      ;;
    k)
      BINTRAY_KEY=$OPTARG
      ;;      
    ?)
      usage
      exit
      ;;
  esac
done

if [[ -z $ARG_PLATFORMS ]] || [[ -z $KONG_VERSION ]] || [[ -z $BINTRAY_USERNAME ]] || [[ -z $BINTRAY_KEY ]]; then
  usage
  exit 1
fi


##############################################################
#                      Check Arguments                       #
##############################################################

supported_platforms=( centos:6 centos:7 debian:7 debian:8 ubuntu:12.04.5 ubuntu:14.04.2 ubuntu:15.04 ubuntu:16.04 aws osx )

platforms_to_release=( )

for var in "$ARG_PLATFORMS"
do
  if [[ "all" == "$var" ]]; then
    platforms_to_release=( "${supported_platforms[@]}" )
  elif ! [[ " ${supported_platforms[*]} " == *" $var "* ]]; then
    echo "[ERROR] \"$var\" not supported. Supported platforms are: "$( IFS=$'\n'; echo "${supported_platforms[*]}" )
    echo "You can optionally specify \"all\" to build all the supported platforms"
    exit 1
  else
    platforms_to_release+=($var)
  fi
done

if [ ${#platforms_to_release[@]} -eq 0 ]; then
  echo "Please specify an argument!"
  exit 1
fi

echo "Releasing Kong $KONG_VERSION: "$( IFS=$'\n'; echo "${platforms_to_release[*]}" )

##############################################################
#                        Start Releasing                         #
##############################################################

# Preparing environment
DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
echo "Current directory is: "$DIR
if [ "$DIR" == "/" ]; then
  DIR=""
fi

MAP=( "debian:6=squeeze" "debian:7=wheezy" "debian:8=jessie" "ubuntu:12.04.5=precise" "ubuntu:14.04.2=trusty" "ubuntu:15.04=vivid" "ubuntu:16.04=xenial")

function get {
  [[ "$#" != 1 ]] && exit 1
  key=$1
  for pair in "${MAP[@]}" ; do
    KEY=${pair%%=*}
    VALUE=${pair#*=}
    if [[ "$KEY" == "$key" ]]
      then
        echo $VALUE
        break
    fi    
  done
}

function echoResponse {
  [[ "$#" != 1 ]] && exit 1
  STATUS=$(echo $1 | awk -F"=" '{print $2}')
  MESSAGE=$(echo $1 | awk -F"=" '{print $1}') 
  if [[ "$STATUS" -ne "201" ]]; then
    echo $MESSAGE   
  fi    
}

KONG_GITHUB_LOC="https://github.com/Mashape/kong/releases/download/"
KONG_MAJOR_VERSION=`echo $KONG_VERSION | sed 's/\([0-9]*.[0-9]*\).*/\1.x/'`
echo $KONG_MAJOR_VERSION
function createRepo {
  REPO_NAME=$1
  REPO_TYPE=$2
  PACKAGE_NAME=$3
  RESPONSE=$(curl -X GET --write-out =%{http_code} --silent --output - -u  $BINTRAY_USERNAME:$BINTRAY_KEY  "https://api.bintray.com/repos/mashape/$REPO_NAME")
  STATUS=$(echo $RESPONSE | awk -F"=" '{print $2}')
  if [[ "$STATUS" -ne "200" ]]; then
    RESPONSE=$(curl -X POST --write-out =%{http_code} --silent --output - -u  $BINTRAY_USERNAME:$BINTRAY_KEY  "https://api.bintray.com/repos/mashape/$REPO_NAME" -H "Content-type: application/json" -d '{ "type": "'$REPO_TYPE'", "private": false, "premium": false, "desc": "Repo for kong​-'$KONG_MAJOR_VERSION'", "labels": [ "Kong", "Mashape" ] }')
    STATUS=$(echo $RESPONSE | awk -F"=" '{print $2}')
    MESSAGE=STATUS=$(echo $RESPONSE | awk -F"=" '{print $1}')
    if [[ "$STATUS" == "201" ]]; then
      RESPONSE=$(curl -X POST --write-out =%{http_code} --silent --output - -u  $BINTRAY_USERNAME:$BINTRAY_KEY  "https://api.bintray.com/packages/mashape/$REPO_NAME" -H "Content-type: application/json" -d '{ "name": "'$PACKAGE_NAME'", "desc": "", "labels": [ "kong", "kong '$REPO_TYPE'" ], "licenses": ["Apache-2.0"], "custom_licenses": [], "vcs_url": "https://github.com/Mashape/kong/",  "website_url": "https://getkong.org/", "issue_tracker_url": "https://github.com/Mashape/kong/issues",  "github_repo": "mashape/kong", "github_release_notes_file": "CHANGELOG.md",  "public_download_numbers": false, "public_stats": true }')
      STATUS=$(echo $RESPONSE | awk -F"=" '{print $2}') 
    fi  
  fi  
}

# Start publishisng
for i in "${platforms_to_release[@]}"
do
  echo "Releasing $i"	
  if [[ "$i" == "osx" ]]; then
    echo "TBD"
  elif [[ "$i" == "aws" ]]; then
    wget -O $DIR/build-output/kong-$KONG_VERSION.aws.rpm https://github.com/Mashape/kong/releases/download/$KONG_VERSION/kong-$KONG_VERSION.aws.rpm 
    if [ -e $DIR/build-output/kong-$KONG_VERSION.aws.rpm ]; then
      echo $(createRepo "kong-rpm-aws-$KONG_MAJOR_VERSION" "rpm" "rpm-aws")
      RESPONSE=$(curl -X PUT --write-out =%{http_code} --silent --output - -u  $BINTRAY_USERNAME:$BINTRAY_KEY  "https://api.bintray.com/content/mashape/kong-rpm-aws-$KONG_MAJOR_VERSION/rpm-aws/$KONG_VERSION/$KONG_VERSION/kong-$KONG_VERSION.aws.rpm?publish=1&override=1" -T $DIR/build-output/kong-$KONG_VERSION.aws.rpm)
      echo $(echoResponse "$RESPONSE")
    else
      echo "Artifact $DIR/build-output/kong-$KONG_VERSION.aws.rpm not found"    
    fi
  else
    case $i in
    centos:*)
      VERSION=$(echo $i | awk -F":" '{print $2}')
      wget -O $DIR/build-output/kong-$KONG_VERSION.el$VERSION.noarch.rpm https://github.com/Mashape/kong/releases/download/$KONG_VERSION/kong-$KONG_VERSION.el$VERSION.noarch.rpm
      if [ -e $DIR/build-output/kong-$KONG_VERSION.el$VERSION.noarch.rpm ]; then
        echo $(createRepo "kong-rpm-el$VERSION-$KONG_MAJOR_VERSION" "rpm" "rpm-el$VERSION")
        RESPONSE=$(curl -X PUT --write-out =%{http_code} --silent --output - -u  $BINTRAY_USERNAME:$BINTRAY_KEY  "https://api.bintray.com/content/mashape/kong-rpm-el$VERSION-$KONG_MAJOR_VERSION/rpm-el$VERSION/$KONG_VERSION/$KONG_VERSION/kong-$KONG_VERSION.el$VERSION.noarch.rpm?publish=1&override=1" -T $DIR/build-output/kong-$KONG_VERSION.el$VERSION.noarch.rpm)
        echo $(echoResponse "$RESPONSE")
      else
        echo "Artifact $DIR/build-output/kong-$KONG_VERSION.el$VERSION.noarch.rpm not found"    
      fi   
      ;;
    [ubuntu,debian]*:*)
      VERSION=$(get "$i")
      ALL=_all
      OS=$(echo $i | awk -F":" '{print $1}')
      wget -O $DIR/build-output/kong-$KONG_VERSION.$VERSION$ALL.deb https://github.com/Mashape/kong/releases/download/$KONG_VERSION/kong-$KONG_VERSION.$VERSION$ALL.deb
	    if [ -e $DIR/build-output/kong-$KONG_VERSION.$VERSION$ALL.deb ]; then
        REPO_STATUS=$(createRepo "kong-$OS-$VERSION-$KONG_MAJOR_VERSION" "debian" "$OS-$VERSION")
        RESPONSE=$(curl -X PUT --write-out =%{http_code} --silent --output - -u  $BINTRAY_USERNAME:$BINTRAY_KEY  "https://api.bintray.com/content/mashape/kong-$OS-$VERSION-$KONG_MAJOR_VERSION/$OS-$VERSION/$KONG_VERSION/dists/kong-$KONG_VERSION.$VERSION$ALL.deb;deb_distribution=$VERSION;deb_component=main;deb_architecture=i386,amd64,noarch;publish=1;override=1" -T $DIR/build-output/kong-$KONG_VERSION.$VERSION$ALL.deb)
        echo $(echoResponse "$RESPONSE")
      else
        echo "Artifact $DIR/build-output/kong-$KONG_VERSION.$VERSION$ALL.deb not found" 
      fi   
      ;; 
    ?)
      usage
      exit
      ;;
  esac 
  fi
  if [ $? -ne 0 ]; then
    exit 1
  fi
done

echo "Version $KONG_VERSION release finished"
