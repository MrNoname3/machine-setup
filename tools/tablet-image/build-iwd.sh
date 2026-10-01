#!/usr/bin/env bash
#
# build-iwd.sh
#
# Builds Debian's iwd with patches/iwd-psk-sha256-needs-mfp.patch into
# $TI_OUT/debs, where build.sh picks it up. Without the patch iwd selects
# PSK-SHA256 on WPA2/WPA3 transition networks even on hardware that cannot do
# management frame protection, and such hardware then never associates.
#
# Runs as root inside a throwaway Debian 13 container with deb-src enabled.
#
set -euo pipefail

SRC=$(dirname "$(readlink -f "$0")")
TI_OUT=${TI_OUT:-$SRC/../../work/tablet}
PATCH=$SRC/patches/iwd-psk-sha256-needs-mfp.patch

die() { printf 'build-iwd.sh: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "must run as root (inside the build container)"

export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq --no-install-recommends dpkg-dev devscripts fakeroot >/dev/null
apt-get build-dep -y -qq iwd >/dev/null || die "apt-get build-dep iwd failed (is deb-src enabled?)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
apt-get source -qq iwd >/dev/null
cd iwd-*/
patch -p1 --dry-run -s <"$PATCH" >/dev/null || die "patch does not apply to $(basename "$PWD")"
cp "$PATCH" debian/patches/
basename "$PATCH" >>debian/patches/series
DEBFULLNAME=tablet-image DEBEMAIL=tablet-image@localhost \
  dch --local +tablet "Only select PSK-SHA256 when the hardware is MFP capable." >/dev/null 2>&1
DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -uc -us >"$WORK/build.log" 2>&1 ||
  { tail -20 "$WORK/build.log"; die "build failed"; }

mkdir -p "$TI_OUT/debs"
rm -f "$TI_OUT"/debs/iwd_*.deb
cp ../iwd_*_amd64.deb "$TI_OUT/debs/"
ls -l "$TI_OUT"/debs/iwd_*.deb
