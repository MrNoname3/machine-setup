#!/usr/bin/env bash
#
# build-deb.sh [--keep-version] <source-package> <binary-package>[,<binary-package>...] <out-dir>
# build-deb.sh --suffix <source-package>
# build-deb.sh --source <revision> <source-package>[=<version>] <out-dir>
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
# prints that "+patched.<hash>". --source builds an unsigned source package for
# a PPA of the running release instead, from the archive's <version> when one
# is named, versioned "+patched<revision>", with the patches in debian/patches
# (or in the tree of a native package). The patches in use:
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
#   mesa                on GeForce 8 and later cards: VA surfaces a browser
#                       can import, safe decoder setup and teardown, the VP2
#                       engines working on two frames at once and keeping
#                       each picture's motion vectors apart, nv50 and nvc0
#                       clears of video surfaces, and Wayland EGL that finds the GPU
#                       without wl_drm (built with --keep-version).
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
KEEP_VERSION= REVISION=
if [ "${1:-}" = --keep-version ]; then
  KEEP_VERSION=1
  shift
elif [ "${1:-}" = --source ]; then
  [ $# -eq 4 ] || die "usage: build-deb.sh --source <revision> <source-package>[=<version>] <out-dir>"
  REVISION=$2
  set -- "$3" "" "$4"
fi
WANT_VERSION=
if [ -n "$REVISION" ] && [[ $1 == *=* ]]; then
  WANT_VERSION=${1#*=}
  set -- "${1%%=*}" "$2" "$3"
fi
[ $# -eq 3 ] || die "usage: build-deb.sh [--keep-version] <source-package> <binary-package>[,...] <out-dir>"
SOURCE=$1 OUT=$(readlink -f "$3")
IFS=, read -ra BINARIES <<<"$2"
SUFFIX=$(suffix "$SOURCE")
PATCHES=("$SRC"/patches/"$SOURCE"-*.patch)

if [ "$(id -u)" = 0 ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq --no-install-recommends dpkg-dev fakeroot >/dev/null
  [ -n "$REVISION" ] ||
    apt-get build-dep -y -qq "$SOURCE" >/dev/null || die "apt-get build-dep $SOURCE failed (is deb-src enabled?)"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
apt-get source -qq "$SOURCE${WANT_VERSION:+=$WANT_VERSION}" >/dev/null 2>&1 ||
  die "apt-get source $SOURCE${WANT_VERSION:+ $WANT_VERSION} failed (is deb-src enabled?)"
cd "$SOURCE"-*/
VERSION=$(dpkg-parsechangelog -S Version)
[ -z "$WANT_VERSION" ] || [ "$VERSION" = "$WANT_VERSION" ] || die "apt-get source gave $SOURCE $VERSION, not $WANT_VERSION"
if [ -n "$REVISION" ]; then
  VERSION=$VERSION+patched$REVISION
elif [ -z "$KEEP_VERSION" ]; then
  VERSION=$VERSION$SUFFIX
fi
UPSTREAM=$(dpkg-parsechangelog -S Version | sed -E 's/^[0-9]+://; s/-[^-]*$//')

# A package an older version of the source built stays installed until
# removed, but there is nothing to rebuild it from.
if [ -z "$REVISION" ]; then
  mapfile -t BUILDS < <(sed -n 's/^Package:[[:space:]]*//p' debian/control)
  WANTED=()
  for b in "${BINARIES[@]}"; do
    if printf '%s\n' "${BUILDS[@]}" | grep -qx -- "$b"; then
      WANTED+=("$b")
    else
      printf 'build-deb.sh: %s %s no longer builds %s, skipped\n' "$SOURCE" "$UPSTREAM" "$b" >&2
    fi
  done
  [ ${#WANTED[@]} -gt 0 ] || die "$SOURCE $UPSTREAM builds none of $2"
  BINARIES=("${WANTED[@]}")
fi

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
# and a binary-only build needs no source diff. A source package for a PPA
# carries them in debian/patches, which dpkg-source applies when it builds.
QUILT=
[ -z "$REVISION" ] || [ "$(cat debian/source/format 2>/dev/null)" != "3.0 (quilt)" ] || QUILT=1
for p in "${PATCHES[@]}"; do
  patch -p1 --dry-run -s <"$p" >/dev/null || die "$(basename "$p") does not apply to $(basename "$PWD")"
  if [ -n "$QUILT" ]; then
    mkdir -p debian/patches
    cp "$p" debian/patches/
    basename "$p" >>debian/patches/series
  else
    patch -p1 -s <"$p"
  fi
done
if [ -z "$KEEP_VERSION" ]; then
  if [ -n "$REVISION" ]; then
    DIST=$(. /etc/os-release && echo "$VERSION_CODENAME")
    CHANGED_BY="${DEBFULLNAME:?DEBFULLNAME is needed for --source} <${DEBEMAIL:?DEBEMAIL is needed for --source}>"
  else
    DIST=UNRELEASED CHANGED_BY="machine-setup <machine-setup@localhost>"
  fi
  {
    printf '%s (%s) %s; urgency=medium\n\n' "$SOURCE" "$VERSION" "$DIST"
    for p in "${PATCHES[@]}"; do
      printf '  * %s\n' "$(sed -n 's/^Description: //p' "$p")"
    done
    printf '\n -- %s  %s\n\n' "$CHANGED_BY" "$(date -R)"
    cat debian/changelog
  } >"$WORK/changelog"
  mv "$WORK/changelog" debian/changelog
fi

if [ -n "$REVISION" ]; then
  # The package is ours now; its maintainer is kept as the original one.
  if ! grep -q '^XSBC-Original-Maintainer:' debian/control; then
    sed -i '0,/^Maintainer: \(.*\)$/s//Maintainer: \1\nXSBC-Original-Maintainer: \1/' debian/control
  fi
  sed -i "0,/^Maintainer: .*$/s//Maintainer: $CHANGED_BY/" debian/control
  dpkg-buildpackage -S -d -nc -sa -us -uc >"$WORK/build.log" 2>&1 ||
    { tail -20 "$WORK/build.log"; die "source build failed"; }
  mkdir -p "$OUT"
  changes=../${SOURCE}_${VERSION#*:}_source.changes
  for f in "$changes" $(awk '/^Files:/ { f = 1; next } /^[^ ]/ { f = 0 } f { print "../" $5 }' "$changes"); do
    cp "$f" "$OUT/"
  done
  ls "$OUT/${SOURCE}_${VERSION#*:}.dsc"
  exit 0
fi

DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -uc -us >"$WORK/build.log" 2>&1 ||
  { tail -20 "$WORK/build.log"; die "build failed"; }

mkdir -p "$OUT"
for b in "${BINARIES[@]}"; do
  rm -f "$OUT/${b}"_*.deb
  cp ../"${b}"_*.deb "$OUT/"
  ls "$OUT/${b}"_*.deb
done
