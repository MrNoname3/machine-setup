#!/usr/bin/env bash
#
# build-nvidia-vaapi-driver.sh <base-url> <dsc> <dsc-sha256>
#
# Builds nvidia-vaapi-driver from a Debian source package for the release this
# container runs, as <Debian version>~local1, and puts the .deb into /out. The
# ~local1 suffix sorts below the same Debian version, so the archive's own
# package of that version replaces it.
#
# Runs as root inside a throwaway container of the host's Ubuntu release.
#
set -euo pipefail

die() { printf 'build-nvidia-vaapi-driver.sh: %s\n' "$*" >&2; exit 1; }
[ $# -eq 3 ] || die "usage: build-nvidia-vaapi-driver.sh <base-url> <dsc> <dsc-sha256>"
BASE=$1 DSC=$2 SHA256=$3

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl dpkg-dev devscripts fakeroot >/dev/null

WORK=$(mktemp -d)
cd "$WORK"
curl -sfLO "$BASE/$DSC" || die "cannot download $DSC"
echo "$SHA256  $DSC" | sha256sum -c --quiet || die "$DSC does not match its pinned checksum"

# The .dsc lists the checksums of the files it unpacks from.
awk '/^Checksums-Sha256:/ {f=1; next} f && /^ / {print $1 "  " $3; next} f {exit}' "$DSC" >sums
while read -r _ file; do
  curl -sfLO "$BASE/$file" || die "cannot download $file"
done <sums
sha256sum -c --quiet sums || die "a source file does not match $DSC"

dpkg-source --no-check -x "$DSC" src >/dev/null
apt-get build-dep -y -qq ./src >/dev/null || die "apt-get build-dep failed"
cd src
DEBFULLNAME=machine-setup DEBEMAIL=machine-setup@localhost \
  dch --local "~local" --distribution UNRELEASED "Rebuilt for this release." >/dev/null 2>&1
DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -uc -us >"$WORK/build.log" 2>&1 ||
  { tail -20 "$WORK/build.log"; die "build failed"; }

cp ../nvidia-vaapi-driver_*_amd64.deb /out/
ls -l /out/nvidia-vaapi-driver_*_amd64.deb
