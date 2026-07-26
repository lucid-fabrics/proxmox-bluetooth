#!/usr/bin/env bash
# Build btproxy from official BlueZ source on a Debian/Ubuntu box.
#
#   ./build.sh            build to build/btproxy-x86_64 and print its SHA-256
#   ./build.sh --write    also replace bin/btproxy-x86_64 and regenerate its .sha256
#
# Without --write the committed binary is left alone, so you can build and compare
# against it. (An earlier version overwrote it unconditionally, which made
# "reproduce it and compare" impossible to actually follow.)
#
# CFLAGS="-O2" replaces autoconf's default "-g -O2": it drops debug info that the
# strip below would remove anyway, and keeps the build to plain optimisation flags.
#
# The SHIPPED binary must be built on Debian 12 (bookworm) - the oldest glibc among
# supported targets (Proxmox 8 host = glibc 2.36). glibc is backward compatible, so a
# bookworm build (needs <= GLIBC_2.34) runs on Proxmox 8/9, Ubuntu, and Fedora guests;
# a build on anything newer needs newer GLIBC symbols and will NOT start on Proxmox 8:
#   docker run --rm --platform linux/amd64 -v "$PWD":/w -w /w debian:bookworm bash build.sh --write
set -euo pipefail

VER=5.66
# SHA-256 of bluez-5.66.tar.xz as published on kernel.org. Pinning the *input* matters:
# without it the whole "reproduces byte-for-byte from upstream source" chain would happily
# attest to whatever tarball the download happened to return.
VER_SHA256=39fea64b590c9492984a0c27a89fc203e1cdc74866086efb8f4698677ab2b574
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$REPO/build/btproxy-x86_64}"

SUDO=sudo; [ "$(id -u)" = 0 ] && SUDO=""
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq build-essential libglib2.0-dev libdbus-1-dev libudev-dev \
    libical-dev libreadline-dev libsbc-dev libspeexdsp-dev libbluetooth-dev libjson-c-dev \
    libasound2-dev libell-dev wget

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

wget -q "https://www.kernel.org/pub/linux/bluetooth/bluez-$VER.tar.xz"
echo "$VER_SHA256  bluez-$VER.tar.xz" | sha256sum -c - \
    || { echo "bluez-$VER.tar.xz does not match the pinned checksum - refusing to build."; exit 1; }
tar xf "bluez-$VER.tar.xz" && cd "bluez-$VER"
CFLAGS="-O2" ./configure --disable-manpages --with-udevdir=/lib/udev \
    --with-systemdsystemunitdir=no --with-systemduserunitdir=no
make -j"$(nproc)" tools/btproxy
strip tools/btproxy

mkdir -p "$(dirname "$OUT")"
cp tools/btproxy "$OUT"
echo "Built: $OUT"
sha256sum "$OUT"
ldd tools/btproxy

if [ "${1:-}" = "--write" ]; then
    cp "$OUT" "$REPO/bin/btproxy-x86_64"
    ( cd "$REPO/bin" && sha256sum btproxy-x86_64 > btproxy-x86_64.sha256 )
    echo
    echo "Wrote bin/btproxy-x86_64 and regenerated bin/btproxy-x86_64.sha256."
    echo "Now update BTPROXY_SHA256 in install.sh to:"
    cut -d' ' -f1 "$REPO/bin/btproxy-x86_64.sha256"
fi
