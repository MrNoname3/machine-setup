#!/usr/bin/env bash
#
# envydis.sh <image> [envydis options]
#
# Disassembles a binary image with envytools' envydis, built from the same
# pinned commit as nvbios.sh, without colours. The options default to a Fermi
# falcon (-m falcon -V fuc3); a code image from falcon-image.py starts at
# virtual address 0.
#
# Runs as root inside a throwaway Debian or Ubuntu container, which needs
# git ca-certificates build-essential cmake flex bison libxml2-dev pkg-config.
#
# Environment:
#   ENVYTOOLS_BUILD  where envytools is built and kept (default /var/tmp/envytools)
#
set -euo pipefail

ENVYTOOLS_URL=https://github.com/envytools/envytools.git
ENVYTOOLS_COMMIT=f102b82381f3f11cee113d16374c87091db039d9

IMAGE=${1:?usage: envydis.sh <image> [envydis options]}
shift
[ $# -gt 0 ] || set -- -m falcon -V fuc3
B=${ENVYTOOLS_BUILD:-/var/tmp/envytools}

if [ ! -x "$B/build/envydis/envydis" ]; then
  if [ ! -f "$B/CMakeLists.txt" ]; then
    rm -rf "$B"
    git init -q "$B"
    git -C "$B" fetch -q --depth 1 "$ENVYTOOLS_URL" "$ENVYTOOLS_COMMIT"
    git -C "$B" checkout -q FETCH_HEAD
  fi
  if ! { cmake -S "$B" -B "$B/build" -DCMAKE_BUILD_TYPE=Release &&
         make -C "$B/build" -j"$(nproc)" envydis; } >"$B/build.log" 2>&1; then
    tail -20 "$B/build.log" >&2
    exit 1
  fi
fi
"$B/build/envydis/envydis" "$@" -i -b 0 <"$IMAGE" | sed -r 's/\x1b\[[0-9;]*m//g'
