#!/usr/bin/env bash
#
# mmt-build.sh <out-dir>
#
# Builds valgrind-mmt, which records what a program writes to the memory it
# maps from the NVIDIA driver, and envytools' demmt, which decodes such a
# recording, from pinned commits, installed under <out-dir>/opt/mmt. The
# result runs on the live system of the 340 image (Ubuntu 20.04): copy
# <out-dir>/opt/mmt to /opt/mmt there, and run demmt with
# RNN_PATH=/opt/mmt/share/envytools/rnndb:/opt/mmt/share/envytools/rnndb-generated
#
# Runs as root inside a throwaway Ubuntu 20.04 container, and installs the
# build tools itself.
#
set -euo pipefail

VALGRIND_URL=https://github.com/envytools/valgrind.git
VALGRIND_COMMIT=90426a34d81e465f5298fae4979c14ae1c506cd3  # branch mmt-3.16.1
ENVYTOOLS_URL=https://github.com/envytools/envytools.git
ENVYTOOLS_COMMIT=f102b82381f3f11cee113d16374c87091db039d9

OUT=$(realpath "${1:?usage: mmt-build.sh <out-dir>}")
B=$(mktemp -d)

export DEBIAN_FRONTEND=noninteractive
apt-get update -q >"$B/deps.log"
apt-get install -y -q git ca-certificates build-essential autoconf automake libtool cmake \
  flex bison python3 libxml2-dev pkg-config libpciaccess-dev libx11-dev libxext-dev libvdpau-dev \
  >>"$B/deps.log"

fetch() { # fetch <url> <commit> <dir>
  git init -q "$3"
  git -C "$3" fetch -q --depth 1 "$1" "$2"
  git -C "$3" checkout -q FETCH_HEAD
}
fetch "$VALGRIND_URL" "$VALGRIND_COMMIT" "$B/valgrind"
fetch "$ENVYTOOLS_URL" "$ENVYTOOLS_COMMIT" "$B/envytools"

if ! { cd "$B/valgrind" && ./autogen.sh && ./configure --prefix=/opt/mmt &&
       make -j"$(nproc)" && make install DESTDIR="$OUT"; } >"$B/valgrind.log" 2>&1; then
  tail -20 "$B/valgrind.log" >&2
  exit 1
fi
if ! { cmake -S "$B/envytools" -B "$B/envytools/build" -DCMAKE_INSTALL_PREFIX=/opt/mmt &&
       make -C "$B/envytools/build" -j"$(nproc)" &&
       make -C "$B/envytools/build" install DESTDIR="$OUT"; } >"$B/envytools.log" 2>&1; then
  tail -20 "$B/envytools.log" >&2
  exit 1
fi
# demmt reads the register databases at run time, from RNN_PATH, and names
# some files by their path from rnndb/: keep the tree's layout.
D=$OUT/opt/mmt/share/envytools
mkdir -p "$D/docs/nvrm"
cp -r "$B/envytools/rnndb" "$D/"
cp -r "$B/envytools/build/rnndb-generated" "$D/"
cp -r "$B/envytools/docs/nvrm/rnndb" "$D/docs/nvrm/"
rm -rf "$B"
