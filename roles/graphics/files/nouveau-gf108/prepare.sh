#!/usr/bin/env bash
#
# prepare.sh <kernel-release> <dkms-source-root>
#
# Builds the DKMS source tree for nouveau with the GF108 patches: the nouveau
# directory of the Ubuntu source package the kernel's modules were built from,
# with the patches beside this script applied. Prints the tree's directory,
# <dkms-source-root>/nouveau-gf108-<version>; an existing one is kept.
#
# The source is fetched from the Ubuntu archive and checked along its signed
# chain: InRelease against the archive keyring, Sources against InRelease, the
# .dsc against Sources, and its files against the .dsc.
#
# Environment:
#   MIRROR   Ubuntu archive (default http://archive.ubuntu.com/ubuntu)
#   SRCPKG, SRCVER   the source package and version, instead of asking dpkg
#
set -euo pipefail

KREL=${1:?usage: prepare.sh <kernel-release> <dkms-source-root>}
ROOT=${2:?usage: prepare.sh <kernel-release> <dkms-source-root>}
HERE=$(dirname "$(readlink -f "$0")")
MIRROR=${MIRROR:-http://archive.ubuntu.com/ubuntu}
KEYRING=/usr/share/keyrings/ubuntu-archive-keyring.gpg

die() { printf 'prepare.sh: %s\n' "$*" >&2; exit 1; }

for t in curl gpgv xz patch python3 sha256sum tar; do
  command -v "$t" >/dev/null || die "missing tool: $t"
done
[ -r "$KEYRING" ] || die "missing $KEYRING"

if [ -z "${SRCPKG:-}" ]; then
  read -r SRCPKG SRCVER < <(dpkg-query -W -f='${source:Package} ${source:Version}\n' \
    "linux-modules-$KREL") || die "no linux-modules-$KREL package"
fi
# Mint names the Ubuntu release it is built on in upstream-release.
# shellcheck disable=SC1091 # the system's own release files
if [ -r /etc/upstream-release/lsb-release ]; then
  CODENAME=$(. /etc/upstream-release/lsb-release && echo "$DISTRIB_CODENAME")
else
  CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
fi
[ -n "$CODENAME" ] || die "cannot tell the Ubuntu release"

# A DKMS version may not contain '~'.
DEST=$ROOT/nouveau-gf108-${SRCVER//\~/-}
if [ -f "$DEST/dkms.conf" ]; then
  echo "$DEST"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

check() { # check <sha256> <file>
  echo "$1  $2" | sha256sum -c --quiet - || die "checksum mismatch: $2"
}

# The .dsc's directory and SHA-256, from the first pocket that has this version.
dsc=
for pocket in updates security; do
  suite=$CODENAME-$pocket
  curl -fsSL -o InRelease "$MIRROR/dists/$suite/InRelease" || continue
  gpgv --keyring "$KEYRING" InRelease 2>/dev/null || die "bad signature: $suite InRelease"
  sum=$(awk '/^SHA256:/ { p = 1; next } /^[^ ]/ { p = 0 }
    p && $3 == "main/source/Sources.xz" { print $1; exit }' InRelease)
  [ -n "$sum" ] || die "no Sources.xz in $suite"
  curl -fsSL -o Sources.xz "$MIRROR/dists/$suite/main/source/Sources.xz"
  check "$sum" Sources.xz
  read -r dir dsc dsum < <(xz -dc Sources.xz | awk -v pkg="$SRCPKG" -v ver="$SRCVER" '
    /^Package:/ { p = $2 == pkg } /^Version:/ { v = $2 } /^Directory:/ { d = $2 }
    /^Checksums-Sha256:/ { c = 1; next } /^[^ ]/ { c = 0 }
    c && p && v == ver && $3 ~ /\.dsc$/ { print d, $3, $1; exit }') || true
  [ -n "$dsc" ] && break
done
[ -n "$dsc" ] || die "$SRCPKG $SRCVER is in neither $CODENAME-updates nor -security"

curl -fsSLO "$MIRROR/$dir/$dsc"
check "$dsum" "$dsc"
awk '/^Checksums-Sha256:/ { c = 1; next } /^[^ ]/ { c = 0 } c { print $1, $3 }' "$dsc" |
  while read -r sum file; do
    curl -fsSLO "$MIRROR/$dir/$file"
    check "$sum" "$file"
  done

# nouveau from the release tarball, then Ubuntu's changes to it.
orig=$(ls ./*.orig.tar.*)
top=$(tar -tf "$orig" | awk -F/ 'NR == 1 { print $1 }')
tar -xf "$orig" --wildcards "$top/drivers/gpu/drm/nouveau/*"
zcat ./*.diff.gz | python3 -I -c '
import re, sys
keep = False
for line in sys.stdin:
    if line.startswith("--- "):
        keep = "/drivers/gpu/drm/nouveau/" in line
    if keep:
        sys.stdout.write(line)
' >nouveau.diff
if [ -s nouveau.diff ]; then
  (cd "$top" && patch -p1 -s --no-backup-if-mismatch <../nouveau.diff) || die "Ubuntu's nouveau changes do not apply"
fi

mkdir -p "$ROOT"
rm -rf "$DEST.part"
cp -a "$top/drivers/gpu/drm/nouveau" "$DEST.part"
for p in "$HERE"/0*.patch; do
  (cd "$DEST.part" && patch -p1 -s --no-backup-if-mismatch <"$p") || die "does not apply: ${p##*/}"
done
series=$(echo "$SRCVER" | cut -d. -f1-2)
sed -e "s/@VERSION@/${SRCVER//\~/-}/" -e "s/@SERIES@/${series//./\\\\.}/" \
  "$HERE/dkms.conf.in" >"$DEST.part/dkms.conf"
mv "$DEST.part" "$DEST"
echo "$DEST"
