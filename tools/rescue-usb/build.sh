#!/usr/bin/env bash
#
# build.sh <public-key-file>...
#
# Builds a SystemRescue ISO that can be booted and then driven entirely over
# SSH: root login with the given keys only, a fixed host key so the client can
# tell it is talking to this stick, SSH reachable from private networks only,
# and a 32-bit UEFI loader for machines with a 64-bit CPU behind 32-bit
# firmware. Next to it goes a Memtest86+ ISO for those same machines.
#
# The result is a directory whose contents are copied onto a Ventoy stick.
# Downloads are verified before use: SystemRescue against its author's signing
# key, Memtest86+ against the hashes pinned below.
#
# Environment:
#   RU_CACHE   downloads (default ~/.cache/rescue-usb)
#   RU_STATE   host key, known_hosts entry and the finished stick directory
#              (default ~/.local/state/rescue-usb). The host key is created on
#              the first run and reused, so a rebuild keeps the same identity.
#
set -euo pipefail

SR_VERSION=13.02
SR_ISO=systemrescue-$SR_VERSION-amd64.iso
SR_URL=https://fastly-cdn.system-rescue.org/releases/$SR_VERSION
SR_KEY_URL=https://www.system-rescue.org/security/signing-keys/gnupg-pubkey-fdupoux-20210704-v001.pem
SR_KEY_FPR=0FF11AF081E98345594812037091115F8320B897

MT_VERSION=8.10
MT_URL=https://www.memtest.org/download/v$MT_VERSION
MT_BIN_ZIP=mt86plus_$MT_VERSION.binaries.zip
MT_BIN_SHA256=7e6c5162cb84ab959aeb9d13c9cfd6976b0dec3b34936b73820b20c55eb26c29
MT_ISO_ZIP=mt86plus_${MT_VERSION}_i586.iso.zip
MT_ISO_SHA256=a55c3a12b6c4d4f444df3e5213aa85045f2629eb0d56e98a06cc31ef1cda51b9

SRC=$(dirname "$(readlink -f "$0")")
RU_CACHE=${RU_CACHE:-$HOME/.cache/rescue-usb}
RU_STATE=${RU_STATE:-$HOME/.local/state/rescue-usb}
STICK=$RU_STATE/stick
HOSTKEY=$RU_STATE/ssh_host_ed25519_key

die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: build.sh <public-key-file>..."

missing=
for t in curl gpg xorriso unsquashfs mksquashfs rsync patch mcopy unzip \
         grub-mkimage ssh-keygen sha256sum sha512sum; do
  command -v "$t" >/dev/null || missing="$missing $t"
done
[ -d /usr/lib/grub/i386-efi ] || missing="$missing grub-efi-ia32-bin(/usr/lib/grub/i386-efi)"
[ -z "$missing" ] || die "missing tools:$missing"

mkdir -p "$RU_CACHE" "$RU_STATE"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/rescue-usb.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

fetch() { # fetch <url> -- into the cache, once
  local f="$RU_CACHE/${1##*/}"
  if [ ! -s "$f" ]; then
    curl -fL --retry 3 -o "$f.part" "$1" || die "download failed: $1"
    mv "$f.part" "$f"
  fi
}

sha256_pinned() { # sha256_pinned <file> <hash>
  echo "$2  $1" | sha256sum -c --quiet - || die "checksum mismatch: $1"
}

echo "=== downloads"
fetch "$SR_URL/$SR_ISO"
fetch "$SR_URL/$SR_ISO.asc"
fetch "$SR_KEY_URL"
fetch "$MT_URL/$MT_BIN_ZIP"
fetch "$MT_URL/$MT_ISO_ZIP"

# A signature only means something from the key pinned here, not from whatever
# key file the download happened to produce.
export GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg -q --import "$RU_CACHE/${SR_KEY_URL##*/}" 2>/dev/null
gpg --status-fd 1 --verify "$RU_CACHE/$SR_ISO.asc" "$RU_CACHE/$SR_ISO" 2>/dev/null |
  grep -q "^\[GNUPG:\] VALIDSIG .* $SR_KEY_FPR\$" || die "bad signature: $SR_ISO"
sha256_pinned "$RU_CACHE/$MT_BIN_ZIP" "$MT_BIN_SHA256"
sha256_pinned "$RU_CACHE/$MT_ISO_ZIP" "$MT_ISO_SHA256"
echo "verified"

echo "=== keys"
if [ ! -f "$HOSTKEY" ]; then
  ssh-keygen -q -t ed25519 -N '' -C rescue-usb -f "$HOSTKEY"
  echo "new host key: $HOSTKEY"
fi
echo "rescue $(cut -d' ' -f1,2 "$HOSTKEY.pub")" >"$RU_STATE/known_hosts"

RECIPE=$WORK/recipe
cp -a "$SRC/recipe" "$RECIPE"
chmod +x "$RECIPE"/iso_patch_and_script/*

nkeys=0
for f in "$@"; do
  while read -r type b64 comment; do
    case "$type" in ''|'#'*) continue ;; esac
    nkeys=$((nkeys + 1))
    printf '        "%s": "%s %s"\n' "${comment:-key$nkeys}" "$type" "$b64" \
      >>"$RECIPE/iso_add/sysrescue.d/500-remote.yaml"
  done <"$f"
done
[ "$nkeys" -gt 0 ] || die "no public keys found in: $*"
echo "$nkeys authorized key(s)"

install -D -m 600 "$HOSTKEY" "$RECIPE/build_into_srm/etc/ssh/ssh_host_ed25519_key"
install -D -m 644 "$HOSTKEY.pub" "$RECIPE/build_into_srm/etc/ssh/ssh_host_ed25519_key.pub"

echo "=== 32-bit UEFI loader"
# Only enough to find the ISO, so it fits the free space in the El Torito EFI
# image; normal mode, the menu and every other module load from boot/grub/ia32.
mkdir -p "$RECIPE/iso_add/EFI/boot" "$RECIPE/iso_add/boot/grub/ia32/i386-efi"
grub-mkimage -O i386-efi -o "$RECIPE/iso_add/EFI/boot/bootia32.efi" \
  -p /boot/grub/ia32 -c "$SRC/grub-ia32.cfg" \
  part_gpt part_msdos iso9660 fat search search_fs_file
cp /usr/lib/grub/i386-efi/*.mod /usr/lib/grub/i386-efi/*.lst \
  "$RECIPE/iso_add/boot/grub/ia32/i386-efi/"
unzip -p "$RU_CACHE/$MT_BIN_ZIP" "mt86p_${MT_VERSION//./}_i586" >"$RECIPE/iso_add/EFI/memtest-ia32.efi"

echo "=== rebuild"
# sysrescue-customize ships inside the verified image; use that copy.
xorriso -osirrox on -indev "$RU_CACHE/$SR_ISO" \
  -extract /sysresccd/x86_64/airootfs.sfs "$WORK/airootfs.sfs" >/dev/null 2>&1
unsquashfs -q -no-xattrs -d "$WORK/tool" "$WORK/airootfs.sfs" \
  usr/share/sysrescue/bin/sysrescue-customize >/dev/null
rm "$WORK/airootfs.sfs"

rm -rf "$STICK"
mkdir -p "$STICK"
OUT_ISO=$STICK/systemrescue-$SR_VERSION-remote.iso
bash "$WORK/tool/usr/share/sysrescue/bin/sysrescue-customize" --auto --overwrite \
  --source="$RU_CACHE/$SR_ISO" --dest="$OUT_ISO" \
  --recipe-dir="$RECIPE" --work-dir="$WORK/customize"
unzip -p "$RU_CACHE/$MT_ISO_ZIP" memtest.iso >"$STICK/memtest86+-$MT_VERSION-i586.iso"

# Ventoy boots the rescue image by itself. Its second menu (normal or grub2
# mode) otherwise waits for a key.
mkdir -p "$STICK/ventoy"
cat >"$STICK/ventoy/ventoy.json" <<EOF
{
  "control": [
    { "VTOY_MENU_TIMEOUT": "10" },
    { "VTOY_DEFAULT_IMAGE": "/${OUT_ISO##*/}" },
    { "VTOY_SECONDARY_TIMEOUT": "5" }
  ]
}
EOF

echo
echo "=== done: copy the contents of this directory onto the Ventoy stick"
(cd "$STICK" && ls -l && sha256sum -- *.iso)
echo
echo "host key: $(ssh-keygen -lf "$HOSTKEY.pub")"
echo "known_hosts entry: $RU_STATE/known_hosts"
