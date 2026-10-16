#!/usr/bin/env bash
#
# build.sh <public-key-file>...
#
# Builds a Linux Mint live ISO for tracing a legacy proprietary NVIDIA driver
# with mmiotrace, on an Ubuntu kernel that has mmiotrace built in. Once a
# machine has booted it, everything happens over SSH: root login with the
# given keys only, a fixed host key, and the NVIDIA modules left unloaded so a
# trace can start before the driver does.
#
# Runs as root inside a throwaway Debian or Ubuntu container; nothing needs
# loop devices or mounts. The download is checked against the hash pinned
# below.
#
# Environment:
#   MLT_DRIVER the driver branch: 390 (default) for Fermi, on Mint 21.3 with
#              Ubuntu's 5.15 kernel and its prebuilt module; 340 for Tesla
#              (GeForce 8 to 300), on Mint 20.3 with Ubuntu's 5.4 kernel and
#              the module built by DKMS
#   MLT_CACHE  downloads (default work/mmiotrace-live in this repository)
#   MLT_OUT    the finished ISO, its SSH host key and known_hosts entry
#              (default ~/.local/state/mmiotrace-live). The host key is created
#              on the first run and reused, so a rebuild keeps the same identity;
#              it is a private key, so this directory stays out of the repository.
#
set -euo pipefail

MLT_DRIVER=${MLT_DRIVER:-390}
case $MLT_DRIVER in
  390)
    MINT_VERSION=21.3
    MINT_SHA256=b284afcc298cc6f5da6ab4d483318c453b2074485974b71b16fdfc7256527cb1
    ISOLINUX_CFG=/isolinux/live.cfg
    MD5_LIST=/md5sum.txt
    ;;
  340)
    MINT_VERSION=20.3
    MINT_SHA256=4d37e6a57513d2cdb4a8a993f48a54b18e0d41e86b651326f1101c34460c4719
    ISOLINUX_CFG=/isolinux/isolinux.cfg
    MD5_LIST=/MD5SUMS
    ;;
  *)
    printf 'build.sh: MLT_DRIVER must be 390 or 340, not %s\n' "$MLT_DRIVER" >&2
    exit 1
    ;;
esac
MINT_ISO=linuxmint-$MINT_VERSION-xfce-64bit.iso
MINT_URL=https://mirrors.edge.kernel.org/linuxmint/stable/$MINT_VERSION
LIVE_HOSTNAME=mmiotrace

SRC=$(dirname "$(readlink -f "$0")")
MLT_CACHE=${MLT_CACHE:-$SRC/../../work/mmiotrace-live}
MLT_OUT=${MLT_OUT:-$HOME/.local/state/mmiotrace-live}
HOSTKEY=$MLT_OUT/ssh_host_ed25519_key
OUT_ISO=$MLT_OUT/linuxmint-$MINT_VERSION-xfce-mmiotrace.iso

die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: build.sh <public-key-file>..."
[ "$(id -u)" = 0 ] || die "must run as root (inside the build container)"
missing=
for t in curl xorriso unsquashfs mksquashfs ssh-keygen sha256sum md5sum chroot proot; do
  command -v "$t" >/dev/null || missing="$missing $t"
done
[ -z "$missing" ] || die "missing tools:$missing"

mkdir -p "$MLT_CACHE" "$MLT_OUT"
# The root file system holds files of many owners, so it stays on the
# container's own storage rather than on a mounted host directory.
WORK=$(mktemp -d "${TMPDIR:-/var/tmp}/mmiotrace-live.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
R=$WORK/root

echo "=== download"
if [ ! -s "$MLT_CACHE/$MINT_ISO" ]; then
  curl -fL --retry 3 -o "$MLT_CACHE/$MINT_ISO.part" "$MINT_URL/$MINT_ISO" ||
    die "download failed: $MINT_URL/$MINT_ISO"
  mv "$MLT_CACHE/$MINT_ISO.part" "$MLT_CACHE/$MINT_ISO"
fi
echo "$MINT_SHA256  $MLT_CACHE/$MINT_ISO" | sha256sum -c --quiet - ||
  die "checksum mismatch: $MINT_ISO"
echo "verified"

echo "=== keys"
grep -hE '^(ssh|ecdsa|sk)-' "$@" >"$WORK/authorized_keys" ||
  die "no public keys found in: $*"
echo "$(wc -l <"$WORK/authorized_keys") authorized key(s)"
if [ ! -f "$HOSTKEY" ]; then
  ssh-keygen -q -t ed25519 -N '' -C mmiotrace-live -f "$HOSTKEY"
  echo "new host key: $HOSTKEY"
fi
echo "$LIVE_HOSTNAME $(cut -d' ' -f1,2 "$HOSTKEY.pub")" >"$MLT_OUT/known_hosts"

echo "=== root file system"
xorriso -osirrox on -indev "$MLT_CACHE/$MINT_ISO" \
  -extract /casper/filesystem.squashfs "$WORK/orig.squashfs" \
  -extract "$ISOLINUX_CFG" "$WORK/live.cfg" \
  -extract /boot/grub/grub.cfg "$WORK/grub.cfg" \
  -extract "$MD5_LIST" "$WORK/md5sum.txt" >/dev/null 2>&1 ||
  die "cannot read $MINT_ISO"
chmod u+w "$WORK"/*.cfg "$WORK/md5sum.txt"

# A container cannot create device nodes, so they are left out here and come
# back as mksquashfs pseudo files with their original numbers and owners.
unsquashfs -lln "$WORK/orig.squashfs" | sed 's/, */,/' | awk '
  function oct(p,  i, v, r) {
    for (i = 0; i < 3; i++) {
      v = (substr(p, 2 + 3*i, 1) == "r") * 4 + (substr(p, 3 + 3*i, 1) == "w") * 2 \
        + (substr(p, 4 + 3*i, 1) ~ /[xs]/)
      r = r v
    }
    return r
  }
  /^[bc]/ {
    split($2, o, "/"); split($3, d, ",")
    sub(/^squashfs-root\//, "", $6)
    print $6, substr($1, 1, 1), oct($1), o[1], o[2], d[1], d[2]
  }' >"$WORK/devices"
# shellcheck disable=SC2046 # one argument per device path, on purpose
unsquashfs -q -no-progress -d "$R" -excludes "$WORK/orig.squashfs" \
  $(cut -d' ' -f1 "$WORK/devices") >/dev/null
rm "$WORK/orig.squashfs"

cp -a "$SRC/overlay/." "$R/"
install -m 600 "$HOSTKEY" "$R/etc/ssh/ssh_host_ed25519_key"
install -m 644 "$HOSTKEY.pub" "$R/etc/ssh/ssh_host_ed25519_key.pub"
install -d -m 700 "$R/root/.ssh"
install -m 600 "$WORK/authorized_keys" "$R/root/.ssh/authorized_keys"

# Name resolution for apt, and no services started by the packages' scripts.
mv "$R/etc/resolv.conf" "$WORK/resolv.conf"
cp /etc/resolv.conf "$R/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' >"$R/usr/sbin/policy-rc.d"
chmod 755 "$R/usr/sbin/policy-rc.d"
install -m 755 "$SRC/customize.sh" "$R/tmp/customize.sh"

# DKMS needs /proc and /dev/fd, which a container cannot mount; proot lends
# the container's own without mounting anything.
proot -0 -r "$R" -b /proc -b /dev -b /sys -w / \
  /usr/bin/env MLT_DRIVER="$MLT_DRIVER" /tmp/customize.sh

rm "$R/tmp/customize.sh" "$R/usr/sbin/policy-rc.d"
mv "$WORK/resolv.conf" "$R/etc/resolv.conf"

set -- "$R"/boot/vmlinuz-*
[ $# = 1 ] || die "expected one kernel in the image, found: $*"
KVER=${1##*/vmlinuz-}
echo "kernel $KVER"

echo "=== image"
# shellcheck disable=SC2016 # the format is dpkg-query's, not the shell's
chroot "$R" dpkg-query -W --showformat='${Package}\t${Version}\n' >"$WORK/filesystem.manifest"
du -sx --block-size=1 "$R" | cut -f1 >"$WORK/filesystem.size"
install -m 644 "$R/boot/vmlinuz-$KVER" "$WORK/vmlinuz"
install -m 644 "$R/boot/initrd.img-$KVER" "$WORK/initrd.lz"
mksquashfs "$R" "$WORK/filesystem.squashfs" -noappend -comp xz -xattrs \
  -pf "$WORK/devices" -quiet -no-progress

# Mint 21.3 names the host on the command line, 20.3 leaves it to casper.
sed -i -e "s/hostname=mint/hostname=$LIVE_HOSTNAME/" \
  -e "/hostname=/!s/boot=casper/boot=casper hostname=$LIVE_HOSTNAME/" \
  "$WORK/live.cfg" "$WORK/grub.cfg"
# isolinux starts the default entry after ten seconds; GRUB needs telling.
sed -i '1i set timeout=10' "$WORK/grub.cfg"

declare -A ISO_PATH=(
  [filesystem.squashfs]=/casper/filesystem.squashfs
  [filesystem.manifest]=/casper/filesystem.manifest
  [filesystem.size]=/casper/filesystem.size
  [vmlinuz]=/casper/vmlinuz
  [initrd.lz]=/casper/initrd.lz
  [live.cfg]=$ISOLINUX_CFG
  [grub.cfg]=/boot/grub/grub.cfg
)
maps=()
for f in "${!ISO_PATH[@]}"; do
  p=${ISO_PATH[$f]}
  sum=$(md5sum <"$WORK/$f" | cut -d' ' -f1)
  sed -i "s|^[0-9a-f]*  \.$p\$|$sum  .$p|" "$WORK/md5sum.txt"
  maps+=(-map "$WORK/$f" "$p")
done
maps+=(-map "$WORK/md5sum.txt" "$MD5_LIST")

rm -f "$OUT_ISO" "$OUT_ISO.part"
xorriso -indev "$MLT_CACHE/$MINT_ISO" -outdev "$OUT_ISO.part" \
  -boot_image any replay "${maps[@]}" >/dev/null 2>&1 ||
  die "xorriso could not write the ISO"
mv "$OUT_ISO.part" "$OUT_ISO"

echo
echo "=== done: copy this ISO onto the Ventoy stick"
ls -l "$OUT_ISO"
(cd "$MLT_OUT" && sha256sum -- "${OUT_ISO##*/}")
echo
echo "host key: $(ssh-keygen -lf "$HOSTKEY.pub")"
echo "known_hosts entry: $MLT_OUT/known_hosts"
