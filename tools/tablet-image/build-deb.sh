#!/usr/bin/env bash
#
# build-deb.sh <source-package> <binary-package>
#
# Builds a Debian package with this tool's patches/<source-package>-*.patch
# applied and puts <binary-package> into $TI_OUT/debs, where build.sh picks it
# up and holds it. The patches in use:
#
#   iwd                 iwd selects PSK-SHA256 on WPA2/WPA3 transition networks
#                       even on hardware that cannot do management frame
#                       protection, and such hardware never associates.
#
# Runs as root inside a throwaway Debian 13 container with deb-src enabled.
#
set -euo pipefail

SRC=$(dirname "$(readlink -f "$0")")
TI_OUT=${TI_OUT:-$SRC/../../work/tablet}

die() { printf 'build-deb.sh: %s\n' "$*" >&2; exit 1; }
[ $# -eq 2 ] || die "usage: build-deb.sh <source-package> <binary-package>"
[ "$(id -u)" = 0 ] || die "must run as root (inside the build container)"
SOURCE=$1 BINARY=$2
PATCHES=("$SRC"/patches/"$SOURCE"-*.patch)
[ -f "${PATCHES[0]}" ] || die "no patches/$SOURCE-*.patch"

export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq --no-install-recommends dpkg-dev devscripts fakeroot >/dev/null
apt-get build-dep -y -qq "$SOURCE" >/dev/null || die "apt-get build-dep $SOURCE failed (is deb-src enabled?)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
apt-get source -qq "$SOURCE" >/dev/null
cd "$SOURCE"-*/
export DEBFULLNAME=tablet-image DEBEMAIL=tablet-image@localhost
entry=(--local +tablet)
for p in "${PATCHES[@]}"; do
  patch -p1 --dry-run -s <"$p" >/dev/null || die "$(basename "$p") does not apply to $(basename "$PWD")"
  cp "$p" debian/patches/
  basename "$p" >>debian/patches/series
  dch "${entry[@]}" "$(sed -n 's/^Description: //p' "$p")" >/dev/null 2>&1
  entry=(--append)
done
DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -uc -us >"$WORK/build.log" 2>&1 ||
  { tail -20 "$WORK/build.log"; die "build failed"; }

mkdir -p "$TI_OUT/debs"
rm -f "$TI_OUT/debs/${BINARY}"_*.deb
cp ../"${BINARY}"_*_amd64.deb "$TI_OUT/debs/"
ls -l "$TI_OUT/debs/${BINARY}"_*.deb
