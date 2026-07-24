#!/usr/bin/env bash
# Rebuild bin/btproxy-x86_64 from BlueZ source on a Debian/Ubuntu box.
# The default BlueZ build injects ASAN/UBSAN debug deps; plain -O2 keeps it libc-only.
set -euo pipefail

VER=5.66
sudo apt-get update -qq
sudo apt-get install -y -qq build-essential libglib2.0-dev libdbus-1-dev libudev-dev \
    libical-dev libreadline-dev libsbc-dev libspeexdsp-dev libbluetooth-dev libjson-c-dev \
    libasound2-dev libell-dev wget

wget -q "https://www.kernel.org/pub/linux/bluetooth/bluez-$VER.tar.xz"
tar xf "bluez-$VER.tar.xz" && cd "bluez-$VER"
CFLAGS="-O2" ./configure --disable-manpages
make -j"$(nproc)" tools/btproxy
strip tools/btproxy
cp tools/btproxy ../bin/btproxy-x86_64
echo "Built: bin/btproxy-x86_64"
ldd tools/btproxy
