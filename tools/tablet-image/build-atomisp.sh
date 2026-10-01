#!/usr/bin/env bash
#
# build-atomisp.sh
#
# Prepares the atomisp camera driver, which Debian does not build, as a DKMS
# source in $TI_OUT/dkms, where build.sh picks it up: the staging driver of the
# kernel release a machine profile names in ATOMISP_TAG, with the profile's
# atomisp/*.patch applied.
#
# Runs as root inside a throwaway Debian 13 container.
#
set -euo pipefail

SRC=$(dirname "$(readlink -f "$0")")
TI_OUT=${TI_OUT:-$SRC/../../work/tablet}
TI_MACHINE=${TI_MACHINE:-}
REPO=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
DIR=drivers/staging/media/atomisp

die() { printf 'build-atomisp.sh: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "must run as root (inside the build container)"
M=$SRC/machines/$TI_MACHINE
[ -n "$TI_MACHINE" ] && [ -f "$M/machine.conf" ] || die "TI_MACHINE must name a machine profile"
ATOMISP_TAG=
# shellcheck source=/dev/null
. "$M/machine.conf"
[ -n "$ATOMISP_TAG" ] || die "$TI_MACHINE sets no ATOMISP_TAG"

export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq --no-install-recommends git ca-certificates >/dev/null

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
git clone -q --depth 1 --branch "$ATOMISP_TAG" --filter=blob:none --sparse "$REPO" "$WORK/linux" 2>/dev/null
git -C "$WORK/linux" sparse-checkout set "$DIR"
for p in "$M"/atomisp/*.patch; do
  git -C "$WORK/linux" apply "$p" || die "$(basename "$p") does not apply to $ATOMISP_TAG"
done

VERSION=${ATOMISP_TAG#v}
OUT=$TI_OUT/dkms/atomisp-$VERSION
rm -rf "$TI_OUT"/dkms/atomisp-*
mkdir -p "$OUT"
cp -r "$WORK/linux/$DIR/." "$OUT/"
# In the tree the driver finds its headers through $(srctree); built on its
# own they sit next to the Makefile.
sed -i 's|^atomisp = $(srctree)/drivers/staging/media/atomisp/$|atomisp = $(src)/|' "$OUT/Makefile"
grep -q '^atomisp = $(src)/$' "$OUT/Makefile" || die "Makefile layout changed in $ATOMISP_TAG"

cat >"$OUT/dkms.conf" <<EOF
PACKAGE_NAME="atomisp"
PACKAGE_VERSION="$VERSION"
MAKE[0]="make -C \${kernel_source_dir} M=\${dkms_tree}/atomisp/$VERSION/build CONFIG_INTEL_ATOMISP=y CONFIG_VIDEO_ATOMISP=m CONFIG_VIDEO_ATOMISP_OV2722=m modules"
CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/atomisp/$VERSION/build clean"
BUILT_MODULE_NAME[0]="atomisp"
DEST_MODULE_LOCATION[0]="/updates/dkms"
BUILT_MODULE_NAME[1]="atomisp_gmin_platform"
BUILT_MODULE_LOCATION[1]="pci/"
DEST_MODULE_LOCATION[1]="/updates/dkms"
BUILT_MODULE_NAME[2]="atomisp-ov2722"
BUILT_MODULE_LOCATION[2]="i2c/"
DEST_MODULE_LOCATION[2]="/updates/dkms"
AUTOINSTALL="yes"
EOF
echo "$OUT"
