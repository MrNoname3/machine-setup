#!/usr/bin/env bash
#
# build.sh <public-key-file>...
#
# Builds a disk image of Debian 13 with the Phosh touch shell for a Bay Trail
# tablet: 64-bit system, 32-bit UEFI firmware. The image is written to an SD
# card or to the internal eMMC as it is, and grows its root file system to the
# size of the device on first boot.
#
# The image carries no secrets. The user logs in automatically and joins Wi-Fi
# on the touch screen; after that the given keys log in as that user over SSH,
# with sudo needing no password, which is how the unlock PIN gets set. Each
# machine creates its own SSH host keys on first boot.
#
# Runs as root inside a throwaway Debian 13 container; nothing needs loop
# devices or mounts.
#
# Environment:
#   TI_OUT       output directory (default work/tablet in this repository)
#   TI_USER      the tablet user, UID 1000 (default tablet)
#   TI_HOSTNAME  (default tablet)
#   TI_VBT       a Video BIOS Table for i915, for firmware that does not hand
#                one over (see README); loaded through i915.vbt_firmware
#   TI_CMDLINE   extra kernel parameters
#   TI_MACHINE   a profile under machines/: its overlay, DKMS modules, ACPI
#                tables, and the VBT, firmware, packages and kernel parameters
#                its machine.conf names
#   TI_FIRMWARE  the directory holding the files a profile names; they are
#                not redistributable, so they live outside the repository
#   TI_DEBS      locally built packages to install and hold, such as the
#                patched iwd from build-deb.sh (default: \$TI_OUT/debs)
#   TI_DKMS      locally prepared DKMS sources, such as the atomisp driver from
#                build-atomisp.sh (default: \$TI_OUT/dkms)
#   TI_OVERLAY   a further directory laid over the root file system
#
set -euo pipefail

SRC=$(dirname "$(readlink -f "$0")")
TI_OUT=${TI_OUT:-$SRC/../../work/tablet}
TI_USER=${TI_USER:-tablet}
TI_HOSTNAME=${TI_HOSTNAME:-tablet}
TI_VBT=${TI_VBT:-}
TI_CMDLINE=${TI_CMDLINE:-}
TI_OVERLAY=${TI_OVERLAY:-}
TI_MACHINE=${TI_MACHINE:-}
TI_FIRMWARE=${TI_FIRMWARE:-}
TI_DEBS=${TI_DEBS:-$TI_OUT/debs}
TI_DKMS=${TI_DKMS:-$TI_OUT/dkms}
SUITE=trixie
MIRROR=http://deb.debian.org/debian
SECURITY=http://security.debian.org/debian-security
ESP_MIB=256
ROOT_SPARE_MIB=1024

die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: build.sh <public-key-file>..."
[ "$(id -u)" = 0 ] || die "must run as root (inside the build container)"
missing=
for t in mmdebstrap mkfs.ext4 mkfs.vfat mcopy sfdisk grub-mkstandalone gcc pkg-config; do
  command -v "$t" >/dev/null || missing="$missing $t"
done
for p in i386-efi x86_64-efi; do
  [ -d /usr/lib/grub/$p ] || missing="$missing grub($p)"
done
[ -z "$missing" ] || die "missing tools:$missing"

mkdir -p "$TI_OUT"
TI_OUT=$(readlink -f "$TI_OUT")
WORK=$(mktemp -d "$TI_OUT/build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

cat "$@" | grep -E '^(ssh|ecdsa)-' >"$WORK/authorized_keys" ||
  die "no public keys found in: $*"

# Programs of the image's own, from src/.
mkdir "$WORK/bin"
# shellcheck disable=SC2046 # pkg-config prints several words on purpose
gcc -O2 -Wall -o "$WORK/bin/autobrightness" "$SRC/src/autobrightness.c" \
  $(pkg-config --cflags --libs gio-2.0) -lm || die "autobrightness did not build"
strip "$WORK/bin/autobrightness"

HOOKS=()
dkms_hooks() {
  for d in "$1"/*/; do
    [ -f "$d/dkms.conf" ] || continue
    HOOKS+=(--customize-hook="mkdir -p \"\$1/usr/src/$(basename "$d")\""
            --customize-hook="sync-in '$(readlink -f "$d")' /usr/src/$(basename "$d")")
  done
}

VBT=; FIRMWARE=(); PACKAGES_EXTRA=(); CMDLINE=
if [ -n "$TI_MACHINE" ]; then
  M=$SRC/machines/$TI_MACHINE
  [ -f "$M/machine.conf" ] || die "no such machine profile: $TI_MACHINE"
  # shellcheck source=/dev/null
  . "$M/machine.conf"
  [ -d "$M/overlay" ] && HOOKS+=(--customize-hook="sync-in '$M/overlay' /")
  dkms_hooks "$M/dkms"
  TI_CMDLINE="$TI_CMDLINE $CMDLINE"
  if [ -n "$VBT" ] && [ -z "$TI_VBT" ]; then
    TI_VBT=$TI_FIRMWARE/$VBT
  fi
  for f in "${FIRMWARE[@]}"; do
    [ -f "$TI_FIRMWARE/${f%%:*}" ] || die "firmware not found in TI_FIRMWARE: ${f%%:*}"
    HOOKS+=(--customize-hook="mkdir -p \"\$1$(dirname "${f#*:}")\""
            --customize-hook="upload '$TI_FIRMWARE/${f%%:*}' '${f#*:}'")
  done
  # Tables the kernel loads over the firmware's; see the acpi-override hook.
  if compgen -G "$M/acpi/*.asl" >/dev/null; then
    command -v iasl >/dev/null || die "missing tools: iasl"
    mkdir "$WORK/acpi"
    for a in "$M"/acpi/*.asl; do
      iasl -p "$WORK/acpi/$(basename "$a" .asl)" "$a" >/dev/null || die "iasl failed: $a"
    done
    HOOKS+=(--customize-hook='mkdir -p "$1/usr/lib/firmware/acpi"'
            --customize-hook="sync-in '$WORK/acpi' /usr/lib/firmware/acpi")
  fi
fi
dkms_hooks "$TI_DKMS"

if [ -n "$TI_OVERLAY" ]; then
  [ -d "$TI_OVERLAY" ] || die "TI_OVERLAY not found: $TI_OVERLAY"
  HOOKS+=(--customize-hook="sync-in '$(readlink -f "$TI_OVERLAY")' /")
fi

if compgen -G "$TI_DEBS/*.deb" >/dev/null; then
  HOOKS+=(--customize-hook='mkdir -p "$1/tmp/debs"'
          --customize-hook="sync-in '$(readlink -f "$TI_DEBS")' /tmp/debs")
fi

VBT_HOOKS=()
if [ -n "$TI_VBT" ]; then
  [ -f "$TI_VBT" ] || die "TI_VBT not found: $TI_VBT"
  VBT_HOOKS=(--customize-hook='mkdir -p "$1/usr/lib/firmware/i915"'
             --customize-hook="upload '$TI_VBT' /usr/lib/firmware/i915/vbt.bin")
  TI_CMDLINE="$TI_CMDLINE i915.vbt_firmware=i915/vbt.bin"
fi

PACKAGES=(
  # base system
  systemd-sysv systemd-timesyncd systemd-repart systemd-zram-generator
  dbus-user-session libpam-systemd polkitd sudo locales tzdata
  console-setup keyboard-configuration zstd
  linux-image-amd64 initramfs-tools
  intel-microcode firmware-brcm80211 firmware-intel-sound wireless-regdb
  e2fsprogs dosfstools iproute2 python3-minimal efibootmgr
  network-manager iwd openssh-server bluez
  unattended-upgrades ca-certificates logrotate
  # out-of-tree modules a machine profile needs, rebuilt on kernel updates
  dkms linux-headers-amd64
  # touch shell, picked by hand: phosh-core would add calendar and online
  # account daemons that a tablet runs for nothing
  phosh phoc squeekboard libcap2-bin dconf-cli libglib2.0-bin gnome-session-bin gnome-settings-daemon
  gnome-control-center xdg-desktop-portal-phosh xdg-desktop-portal-gtk
  pipewire-pulse libcanberra-pulse wireplumber rtkit alsa-ucm-conf iio-sensor-proxy upower
  feedbackd at-spi2-core
  adwaita-icon-theme fonts-cantarell fonts-noto-core libjxl-gdk-pixbuf
  gnome-console
  # boot splash: the firmware's logo with a spinner
  plymouth plymouth-themes
  # applications
  firefox-esr firefox-esr-l10n-hu firefox-esr-mobile-config
  foliate celluloid i965-va-driver
  "${PACKAGES_EXTRA[@]}"
)

echo "=== root file system"
mmdebstrap --mode=root --variant=apt \
  --include="$(IFS=,; echo "${PACKAGES[*]}")" \
  --aptopt='APT::Install-Recommends "false"' \
  --customize-hook="sync-in '$SRC/overlay' /" \
  --customize-hook="upload '$WORK/authorized_keys' /tmp/authorized_keys" \
  --customize-hook="copy-in '$WORK/bin/autobrightness' /usr/local/bin" \
  "${VBT_HOOKS[@]}" "${HOOKS[@]}" \
  --customize-hook="upload '$SRC/customize.sh' /tmp/customize.sh" \
  --customize-hook="chroot \"\$1\" env TI_USER='$TI_USER' TI_HOSTNAME='$TI_HOSTNAME' sh /tmp/customize.sh" \
  --customize-hook='rm "$1/tmp/customize.sh"' \
  "$SUITE" "$WORK/root" \
  "deb $MIRROR $SUITE main contrib non-free-firmware" \
  "deb $MIRROR $SUITE-updates main contrib non-free-firmware" \
  "deb $SECURITY $SUITE-security main contrib non-free-firmware"

echo "=== partitions"
ROOT_UUID=$(cat /proc/sys/kernel/random/uuid)
ESP_ID=$(printf '%08X' $((RANDOM << 16 | RANDOM)))
ESP_UUID="${ESP_ID:0:4}-${ESP_ID:4:4}"
sed -e "s/@ROOT_UUID@/$ROOT_UUID/g" -e "s/@ESP_UUID@/$ESP_UUID/g" \
  "$SRC/fstab.in" >"$WORK/root/etc/fstab"

# One GRUB per firmware word size. Both boot the kernel through Debian's
# /vmlinuz symlinks, so kernel updates never have to touch the ESP.
sed -e "s/@ROOT_UUID@/$ROOT_UUID/g" -e "s|@CMDLINE@|${TI_CMDLINE# }|" \
  "$SRC/grub.cfg.in" >"$WORK/grub.cfg"
mods="part_gpt ext2 search search_fs_uuid linux normal configfile echo test all_video efi_gop gfxterm loadenv keystatus"
grub-mkstandalone -O i386-efi -o "$WORK/BOOTIA32.EFI" --modules="$mods" \
  --locales= --fonts= --themes= "boot/grub/grub.cfg=$WORK/grub.cfg"
grub-mkstandalone -O x86_64-efi -o "$WORK/BOOTX64.EFI" --modules="$mods" \
  --locales= --fonts= --themes= "boot/grub/grub.cfg=$WORK/grub.cfg"

truncate -s ${ESP_MIB}M "$WORK/esp.img"
mkfs.vfat -F 32 -n ESP -i "$ESP_ID" "$WORK/esp.img" >/dev/null
mmd -i "$WORK/esp.img" ::/EFI ::/EFI/BOOT
mcopy -i "$WORK/esp.img" "$WORK/BOOTIA32.EFI" "$WORK/BOOTX64.EFI" ::/EFI/BOOT/

root_mib=$(( $(du -sm "$WORK/root" | cut -f1) * 11 / 10 + ROOT_SPARE_MIB ))
mkfs.ext4 -q -L root -U "$ROOT_UUID" -d "$WORK/root" "$WORK/root.img" ${root_mib}M

echo "=== disk image"
IMG=$TI_OUT/tablet-debian13-phosh.img
disk_mib=$((1 + ESP_MIB + root_mib + 1))
rm -f "$IMG"
truncate -s ${disk_mib}M "$IMG"
# The root partition carries the x86-64 root type, which is what
# systemd-repart matches to grow it on first boot.
sfdisk -q "$IMG" <<EOF
label: gpt
start=1MiB, size=${ESP_MIB}MiB, type=uefi, name=ESP
size=${root_mib}MiB, type=4f68bce3-e8cd-4db1-96e7-fbcaf984b709, name=root
EOF
dd if="$WORK/esp.img" of="$IMG" bs=1M seek=1 conv=notrunc status=none
dd if="$WORK/root.img" of="$IMG" bs=1M seek=$((1 + ESP_MIB)) conv=notrunc status=none

echo
echo "=== done: $IMG ($disk_mib MiB)"
echo "root UUID $ROOT_UUID, user $TI_USER, hostname $TI_HOSTNAME"
echo "kernel parameters: ${TI_CMDLINE# }"
