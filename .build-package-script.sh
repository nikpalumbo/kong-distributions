#!/bin/bash

set -o errexit

# Check Kong version
if [ -z "$1" ]; then
  echo "Specify a Kong version"
  exit 1
fi
KONG_BRANCH=$1

IS_AWS=false
if [[ -n "$2" && $2 = "-aws" ]]; then
  IS_AWS=true
fi

# Preparing environment
DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
echo "Current directory is: "$DIR
if [ "$DIR" == "/" ]; then
  DIR=""
fi
OUT=/tmp/build/out
TMP=/tmp/build/tmp
echo "Cleaning directories"
rm -rf $OUT
rm -rf $TMP
echo "Preparing environment"
mkdir -p $OUT
mkdir -p $TMP

# Load dependencies versions
LUA_VERSION=5.1.4
LUAJIT_VERSION=2.1.0-beta2
PCRE_VERSION=8.40
LUAROCKS_VERSION=2.4.2
OPENRESTY_VERSION=1.11.2.2
OPENSSL_VERSION=1.0.2k
SERF_VERSION=0.7.0

# Variables to be used in the build process
PACKAGE_TYPE=""
MKTEMP_LUAROCKS_CONF=""
MKTEMP_POSTSCRIPT_CONF=""
LUA_MAKE=""
LUAJIT_MAKE=""
OPENRESTY_CONFIGURE=""
FPM_PARAMS=""
FINAL_FILE_NAME=""
LUAROCKS_PARAMS=""

FINAL_BUILD_OUTPUT="/build-data/build-output"

if [ "$(uname)" = "Darwin" ]; then
  brew install gpg
  #brew install ruby

  PACKAGE_TYPE="osxpkg"
  LUA_MAKE="macosx"
  MKTEMP_LUAROCKS_CONF="-t rocks_config.lua"
  MKTEMP_POSTSCRIPT_CONF="-t post_install_script.sh"
  FPM_PARAMS="--osxpkg-identifier-prefix org.kong"
  FINAL_FILE_NAME_SUFFIX=".osx.pkg"
  LUAROCKS_PARAMS="OPENSSL_DIR=/usr/local/opt/openssl OPENSSL_LIBDIR=/usr/local/opt/openssl/lib"

  FINAL_BUILD_OUTPUT="$DIR/build-output"
elif hash yum 2>/dev/null; then
  yum -y install epel-release
  yum -y groupinstall "Development Tools"
  yum -y install wget tar make curl ldconfig gcc perl pcre-devel openssl-devel ldconfig unzip git rpm-build ncurses-devel which lua-$LUA_VERSION lua-devel-$LUA_VERSION gpg pkgconfig xz-devel ruby-devel

  FPM_PARAMS="-d 'epel-release' -d 'openssl' -d 'pcre' -d 'perl'"
  if [[ $IS_AWS == true ]]; then
    FPM_PARAMS=$FPM_PARAMS" -d 'openssl098e'"
    FINAL_FILE_NAME_SUFFIX=".aws.rpm"
  else
    CENTOS_VERSION=`cat /etc/redhat-release | grep -oE '[0-9]+\.[0-9]+'`
    FINAL_FILE_NAME_SUFFIX=".el${CENTOS_VERSION%.*}.noarch.rpm"
  fi

  # Install Ruby for fpm
  cd $TMP
  wget https://cache.ruby-lang.org/pub/ruby/2.2/ruby-2.2.5.tar.gz --no-check-certificate
  tar xvfvz ruby-2.2.5.tar.gz
  cd ruby-2.2.5
  ./configure
  make
  make install
  gem update --system

  PACKAGE_TYPE="rpm"
  LUA_MAKE="linux"
elif hash apt-get 2>/dev/null; then
  apt-get update && apt-get -y --force-yes install wget curl gnupg tar make gcc libreadline-dev libncurses5-dev libpcre3-dev libssl-dev perl unzip git lua${LUA_VERSION%.*} liblua${LUA_VERSION%.*}-0-dev lsb-release

  # Install Ruby for fpm
  cd $TMP
  wget https://cache.ruby-lang.org/pub/ruby/2.2/ruby-2.2.5.tar.gz --no-check-certificate
  tar xvfvz ruby-2.2.5.tar.gz
  cd ruby-2.2.5
  ./configure
  make
  make install
  gem update --system

  DEBIAN_VERSION=`lsb_release -cs`
  PACKAGE_TYPE="deb"
  LUA_MAKE="linux"
  FPM_PARAMS="-d 'openssl' -d 'libpcre3' -d 'procps' -d 'perl'"
  FINAL_FILE_NAME_SUFFIX=".${DEBIAN_VERSION}_all.deb"
else
  echo "Unsupported platform"
  exit 1
fi

export PATH=$PATH:${OUT}/usr/local/bin:$(gem environment | awk -F': *' '/EXECUTABLE DIRECTORY/ {print $2}')

# Check if the Kong version exists
if ! [ `curl -s -o /dev/null -w "%{http_code}" https://github.com/Mashape/kong/tree/$KONG_BRANCH` == "200" ]; then
  echo "Kong version \"$KONG_BRANCH\" doesn't exist!"
  exit 1
else
  echo "Building Kong: $KONG_BRANCH"
fi

# Download OpenSSL
cd $TMP
wget ftp://ftp.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz -O openssl-$OPENSSL_VERSION.tar.gz
tar xzf openssl-$OPENSSL_VERSION.tar.gz
if [ "$(uname)" = "Darwin" ]; then # Checking if OS X
  export KERNEL_BITS=64 # This sets the right OpenSSL variable for OS X
fi

# PCRE for JITy goodness
wget https://ftp.pcre.org/pub/pcre/pcre-$PCRE_VERSION.tar.gz -O pcre-$PCRE_VERSION.tar.gz
tar xzf pcre-$PCRE_VERSION.tar.gz

OPENRESTY_CONFIGURE="--with-openssl=$TMP/openssl-$OPENSSL_VERSION --with-pcre=$TMP/pcre-$PCRE_VERSION --without-luajit-lua52"

# Install fpm
gem install fpm

##############################################################
# Starting building software (to be included in the package) #
##############################################################

if [ "$(uname)" = "Darwin" ]; then
  # Install PCRE
  cd $TMP
  wget ftp://ftp.csx.cam.ac.uk/pub/software/programming/pcre/pcre-$PCRE_VERSION.tar.gz
  tar xzf pcre-$PCRE_VERSION.tar.gz
  cd pcre-$PCRE_VERSION
  ./configure
  make
  make install DESTDIR=$OUT
  cd $OUT

  # Install Lua
  cd $TMP
  wget http://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz
  tar xzf lua-$LUA_VERSION.tar.gz
  cd lua-$LUA_VERSION
  make $LUA_MAKE
  make install INSTALL_TOP=$OUT/usr/local
  cd $OUT

  # Copy libcrypto
  # mkdir -p $OUT/usr/local/lib/
  # cp /usr/local/lib/libcrypto.1.1.dylib $OUT/usr/local/lib/libcrypto.1.1.dylib

  OPENRESTY_CONFIGURE=$OPENRESTY_CONFIGURE" --with-cc-opt=-I$OUT/usr/local/include --with-ld-opt=-L$OUT/usr/local/lib -j8"
fi

cd $TMP
wget https://openresty.org/download/openresty-$OPENRESTY_VERSION.tar.gz
tar xzf openresty-$OPENRESTY_VERSION.tar.gz
cd openresty-$OPENRESTY_VERSION
./configure --with-pcre-jit --with-ipv6 --with-http_realip_module --with-http_ssl_module --with-http_stub_status_module --with-http_v2_module ${OPENRESTY_CONFIGURE}
make
make install DESTDIR=$OUT

cd $TMP
wget http://luajit.org/download/LuaJIT-$LUAJIT_VERSION.tar.gz
tar xzf LuaJIT-$LUAJIT_VERSION.tar.gz
cd LuaJIT-$LUAJIT_VERSION
make $LUAJIT_MAKE
make install DESTDIR=$OUT
if [ "$(uname)" = "Darwin" ]; then
  sudo make install
else
  make install # Install also on the build system
fi
mv $OUT/usr/local/bin/luajit-$LUAJIT_VERSION $OUT/usr/local/bin/luajit
mv /usr/local/bin/luajit-$LUAJIT_VERSION /usr/local/bin/luajit
cd $OUT

# Install LuaRocks
cd $TMP
wget http://luarocks.org/releases/luarocks-$LUAROCKS_VERSION.tar.gz
tar xzf luarocks-$LUAROCKS_VERSION.tar.gz
cd luarocks-$LUAROCKS_VERSION
./configure --with-lua-include=/usr/local/include/luajit-2.1 --lua-suffix=jit --lua-version=5.1 --with-lua=/usr/local
make build
make install DESTDIR=$OUT
cd $OUT

# Configure LuaRocks
rocks_config=$(mktemp $MKTEMP_LUAROCKS_CONF)
echo "
rocks_trees = {
   { name = [[system]], root = [[${OUT}/usr/local]] }
}
" > $rocks_config

export LUAROCKS_CONFIG=$rocks_config
export LUA_PATH=${OUT}/usr/local/share/lua/5.1/?.lua

# Install Serf
cd $TMP
if [ "$(uname)" = "Darwin" ]; then
  wget https://releases.hashicorp.com/serf/${SERF_VERSION}/serf_${SERF_VERSION}_darwin_amd64.zip --no-check-certificate
  unzip serf_${SERF_VERSION}_darwin_amd64.zip
else
  wget https://releases.hashicorp.com/serf/${SERF_VERSION}/serf_${SERF_VERSION}_linux_amd64.zip --no-check-certificate
  unzip serf_${SERF_VERSION}_linux_amd64.zip
fi
mkdir -p $OUT/usr/local/bin/
cp serf $OUT/usr/local/bin/

# Install Kong
cd $TMP
git clone https://github.com/Mashape/kong.git
cd kong
git checkout $KONG_BRANCH
$OUT/usr/local/bin/luarocks make kong-*.rockspec $LUAROCKS_PARAMS

# Extract the version from the rockspec file
rockspec_filename=`basename $TMP/kong/kong-*.rockspec`
rockspec_basename=${rockspec_filename%.*}
rockspec_version=${rockspec_basename#"kong-"}

cp $TMP/kong/bin/kong $OUT/usr/local/bin/kong

# Fix the Kong bin file
sed -i.bak 's@#!/usr/bin/env resty@#!/usr/bin/env /usr/local/openresty/bin/resty@g' $OUT/usr/local/bin/kong
rm $OUT/usr/local/bin/kong.bak

# Copy the conf file for later
cp $TMP/kong/kong.conf.default $OUT/usr/local/lib/luarocks/rocks/kong/$rockspec_version/kong.conf.default

# Create Kong folder and default logging files, and SSL folder
mkdir -p $OUT/usr/local/kong

# Copy the conf to /etc/kong
post_install_script=$(mktemp $MKTEMP_POSTSCRIPT_CONF)
echo "#!/bin/sh
mkdir -p /etc/kong
mv /usr/local/lib/luarocks/rocks/kong/$rockspec_version/kong.conf.default /etc/kong/kong.conf.default
chmod -R 777 /usr/local/kong/
" > $post_install_script

##############################################################
#                      Build the package                     #
##############################################################

# Build proper version
initial_letter="$(echo $KONG_BRANCH | head -c 1)"
re='^[0-9]+$' # to check it's a number
if ! [[ $initial_letter =~ $re ]] ; then
  KONG_VERSION="${rockspec_version%-*}${KONG_BRANCH//[-\/]/}"
elif [ $PACKAGE_TYPE == "rpm" ]; then
  KONG_VERSION=${KONG_BRANCH//[-\/]/}
else
  KONG_VERSION=$KONG_BRANCH
fi

# Execute fpm
cd $OUT
eval "fpm -a all -f -s dir -t $PACKAGE_TYPE -n 'kong' -v $KONG_VERSION $FPM_PARAMS \
--description 'Kong is an open distributed platform for your APIs, focused on high performance and reliability.' \
--vendor Mashape \
--license MIT \
--url http://getkong.org/ \
--after-install $post_install_script \
usr"

# Copy file to host
mkdir -p $FINAL_BUILD_OUTPUT
cp $(find $OUT -maxdepth 1 -type f -name "kong*.*" | head -1) $FINAL_BUILD_OUTPUT/kong-$KONG_VERSION$FINAL_FILE_NAME_SUFFIX

echo "DONE"
