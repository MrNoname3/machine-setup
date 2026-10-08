#!/usr/bin/env bash
#
# nvbios.sh <vbios.rom>
#
# Decodes an NVIDIA VBIOS with envytools' nvbios: its tables, among them the
# performance levels with each clock domain's frequency and flags, and the
# memory timings. Builds nvbios from the pinned envytools commit first.
#
# Runs as root inside a throwaway Debian or Ubuntu container, which needs
# git ca-certificates build-essential cmake flex bison libxml2-dev pkg-config.
# nouveau exposes a GPU's VBIOS as /sys/kernel/debug/dri/<n>/vbios.rom. A
# VBIOS is the board maker's firmware: decode it, do not publish it.
#
# Environment:
#   NVBIOS_BUILD  where envytools is built and kept (default /var/tmp/envytools)
#
set -euo pipefail

ENVYTOOLS_URL=https://github.com/envytools/envytools.git
ENVYTOOLS_COMMIT=f102b82381f3f11cee113d16374c87091db039d9

ROM=${1:?usage: nvbios.sh <vbios.rom>}
B=${NVBIOS_BUILD:-/var/tmp/envytools}

if [ ! -x "$B/build/nvbios/nvbios" ]; then
  rm -rf "$B"
  git init -q "$B"
  git -C "$B" fetch -q --depth 1 "$ENVYTOOLS_URL" "$ENVYTOOLS_COMMIT"
  git -C "$B" checkout -q FETCH_HEAD
  if ! { cmake -S "$B" -B "$B/build" -DCMAKE_BUILD_TYPE=Release &&
         make -C "$B/build" -j"$(nproc)" nvbios; } >"$B/build.log" 2>&1; then
    tail -20 "$B/build.log" >&2
    exit 1
  fi
fi
exec "$B/build/nvbios/nvbios" "$ROM"
