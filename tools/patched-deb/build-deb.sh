#!/usr/bin/env bash
#
# build-deb.sh [--keep-version] <source-package> <binary-package>[,<binary-package>...] <out-dir>
# build-deb.sh --suffix <source-package>
#
# Rebuilds a Debian or Ubuntu source package with patches/<source-package>-*.patch
# applied and copies the named binary packages' .debs into <out-dir>. A patch
# named <source-package>-<name>.<version>.patch replaces <source-package>-<name>.patch
# when the upstream version starts with <version>. --keep-version builds with the
# archive's version and changelog, for a source whose packages are installed
# for more than one architecture: only the native ones are rebuilt, and the
# others must keep matching their version. The version gets
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
#   xwayland            a compositor offering only linux-dmabuf v3 without
#                       wl_drm names no GPU, and glamor stays off; the boot
#                       VGA device's render node is taken there.
#   muffin              without the presentation-time protocol Chromium paces
#                       its frames off a timer the frame callbacks re-phase,
#                       and drops frames of 30 fps video.
#   mesa                on GeForce 8 to 300 cards: VA surfaces a browser can
#                       import, safe decoder teardown, nv50 clears of video
#                       surfaces, and Wayland EGL that finds the GPU without
#                       wl_drm (built with --keep-version).
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
KEEP_VERSION=
if [ "${1:-}" = --keep-version ]; then
  KEEP_VERSION=1
  shift
fi
[ $# -eq 3 ] || die "usage: build-deb.sh [--keep-version] <source-package> <binary-package>[,...] <out-dir>"
SOURCE=$1 OUT=$(readlink -f "$3")
IFS=, read -ra BINARIES <<<"$2"
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
VERSION=$(dpkg-parsechangelog -S Version)
[ -n "$KEEP_VERSION" ] || VERSION=$VERSION$SUFFIX
UPSTREAM=$(dpkg-parsechangelog -S Version | sed -E 's/^[0-9]+://; s/-[^-]*$//')

# Per <name>, the variant for the longest matching version prefix, else the plain patch.
declare -A PICK=() PICKLEN=()
for p in "${PATCHES[@]}"; do
  base=$(basename "$p" .patch) name=${base%%.*} ver=
  [ "$base" = "$name" ] || ver=${base#*.}
  if [ -n "$ver" ] && [[ $UPSTREAM != "$ver"* ]]; then
    continue
  fi
  if [ -z "${PICK[$name]:-}" ] || [ "${#ver}" -gt "${PICKLEN[$name]}" ]; then
    PICK[$name]=$p PICKLEN[$name]=${#ver}
  fi
done
[ ${#PICK[@]} -gt 0 ] || die "no patch fits $SOURCE $UPSTREAM"
mapfile -t PATCHES < <(printf '%s\n' "${PICK[@]}" | sort)

# Applied to the tree itself: a native source package ignores debian/patches,
# and a binary-only build needs no source diff.
for p in "${PATCHES[@]}"; do
  patch -p1 --dry-run -s <"$p" >/dev/null || die "$(basename "$p") does not apply to $(basename "$PWD")"
  patch -p1 -s <"$p"
done
if [ -z "$KEEP_VERSION" ]; then
  {
    printf '%s (%s) UNRELEASED; urgency=medium\n\n' "$SOURCE" "$VERSION"
    for p in "${PATCHES[@]}"; do
      printf '  * %s\n' "$(sed -n 's/^Description: //p' "$p")"
    done
    printf '\n -- machine-setup <machine-setup@localhost>  %s\n\n' "$(date -R)"
    cat debian/changelog
  } >"$WORK/changelog"
  mv "$WORK/changelog" debian/changelog
fi

DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -uc -us >"$WORK/build.log" 2>&1 ||
  { tail -20 "$WORK/build.log"; die "build failed"; }

mkdir -p "$OUT"
for b in "${BINARIES[@]}"; do
  rm -f "$OUT/${b}"_*.deb
  cp ../"${b}"_*.deb "$OUT/"
  ls "$OUT/${b}"_*.deb
done
