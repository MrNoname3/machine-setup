#!/usr/bin/env bash
#
# build-deb.sh <source-package> <binary-package> <out-dir>
# build-deb.sh --suffix <source-package>
#
# Rebuilds a Debian or Ubuntu source package with patches/<source-package>-*.patch
# applied and copies <binary-package>'s .deb into <out-dir>. The version gets
# "+patched.<hash>" appended, the hash covering the patches, so the same source
# version with the same patches always builds the same version; --suffix
# prints that "+patched.<hash>". The patches in use:
#
#   iwd                 iwd selects PSK-SHA256 on WPA2/WPA3 transition networks
#                       even on hardware that cannot do management frame
#                       protection, and such hardware never associates.
#   intel-vaapi-driver  exporting a surface before anything rendered to it
#                       fails, so Chromium's VA-API decoder falls back to
#                       software.
#
# Run as root, as in a throwaway container, it installs the build tools and
# dependencies itself; run as a user, they must be installed already. Either
# way apt needs deb-src entries for the source package.
#
set -euo pipefail
SRC=$(dirname "$(readlink -f "$0")")
die() { printf 'build-deb.sh: %s\n' "$*" >&2; exit 1; }

suffix() {
  compgen -G "$SRC/patches/$1-*.patch" >/dev/null || die "no patches/$1-*.patch"
  printf '+patched.%s\n' "$(cat "$SRC"/patches/"$1"-*.patch | sha256sum | cut -c1-8)"
}

if [ "${1:-}" = --suffix ]; then
  [ $# -eq 2 ] || die "usage: build-deb.sh --suffix <source-package>"
  suffix "$2"
  exit
fi
[ $# -eq 3 ] || die "usage: build-deb.sh <source-package> <binary-package> <out-dir>"
SOURCE=$1 BINARY=$2 OUT=$(readlink -f "$3")
SUFFIX=$(suffix "$SOURCE")
PATCHES=("$SRC"/patches/"$SOURCE"-*.patch)

if [ "$(id -u)" = 0 ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq --no-install-recommends dpkg-dev fakeroot >/dev/null
  apt-get build-dep -y -qq "$SOURCE" >/dev/null || die "apt-get build-dep $SOURCE failed (is deb-src enabled?)"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
apt-get source -qq "$SOURCE" >/dev/null 2>&1 || die "apt-get source $SOURCE failed (is deb-src enabled?)"
cd "$SOURCE"-*/
VERSION=$(dpkg-parsechangelog -S Version)$SUFFIX

mkdir -p debian/patches
for p in "${PATCHES[@]}"; do
  patch -p1 --dry-run -s <"$p" >/dev/null || die "$(basename "$p") does not apply to $(basename "$PWD")"
  cp "$p" debian/patches/
  basename "$p" >>debian/patches/series
done
{
  printf '%s (%s) UNRELEASED; urgency=medium\n\n' "$SOURCE" "$VERSION"
  for p in "${PATCHES[@]}"; do
    printf '  * %s\n' "$(sed -n 's/^Description: //p' "$p")"
  done
  printf '\n -- machine-setup <machine-setup@localhost>  %s\n\n' "$(date -R)"
  cat debian/changelog
} >"$WORK/changelog"
mv "$WORK/changelog" debian/changelog

DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -uc -us >"$WORK/build.log" 2>&1 ||
  { tail -20 "$WORK/build.log"; die "build failed"; }

mkdir -p "$OUT"
rm -f "$OUT/${BINARY}"_*.deb
cp ../"${BINARY}"_*.deb "$OUT/"
ls "$OUT/${BINARY}"_*.deb
