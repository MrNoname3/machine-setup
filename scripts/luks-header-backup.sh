#!/usr/bin/env bash
# Back up the LUKS header of every encrypted partition on this machine.
#
#   ./scripts/luks-header-backup.sh [-n NAME] [-f] DIR
#
# Writes DIR/luks-header-NAME-DISK.img per partition and DIR/SHA256SUMS-NAME.
# NAME defaults to the short hostname; DISK is "system" for the partition that
# holds /, otherwise its partition label without "-crypt", its LUKS label or its
# kernel name. Every backup is checked against its partition's UUID. -f replaces
# backups that already exist. sudo asks for the password (sudo -A when
# SUDO_ASKPASS is set).
#
# A header backup keeps the key slots it was taken with, so after adding or
# removing a key take a new one and delete the old.
set -euo pipefail

usage() { echo "usage: $0 [-n NAME] [-f] DIR" >&2; exit 2; }

name=$(hostname -s)
force=false
while getopts n:f opt; do
  case $opt in
    n) name=$OPTARG ;;
    f) force=true ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage
dir=$1
[ -d "$dir" ] || { echo "$dir is not a directory" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then sudo=()
elif [ -n "${SUDO_ASKPASS:-}" ]; then sudo=(sudo -A)
else sudo=(sudo)
fi
umask 077

mapfile -t parts < <(lsblk -rnpo PATH,FSTYPE | awk '$2 == "crypto_LUKS" { print $1 }')
[ ${#parts[@]} -gt 0 ] || { echo "no LUKS partition on this machine" >&2; exit 1; }

declare -A taken=()
files=()
for part in "${parts[@]}"; do
  if lsblk -nlo MOUNTPOINTS "$part" | grep -qxE '/|/sysroot'; then
    disk=system
  else
    disk=$(lsblk -dno PARTLABEL "$part")
    disk=${disk%-crypt}
    [ -n "$disk" ] || disk=$(lsblk -dno LABEL "$part")
    [ -n "$disk" ] || disk=$(basename "$part")
  fi
  disk=$(printf '%s' "$disk" | tr -c 'A-Za-z0-9._-' '_')
  [ -z "${taken[$disk]:-}" ] || disk=$disk-$(basename "$part")
  taken[$disk]=1

  file=$dir/luks-header-$name-$disk.img
  if [ -e "$file" ]; then
    $force || { echo "$file exists (-f replaces it)" >&2; exit 1; }
    rm -f "$file"
  fi
  "${sudo[@]}" cryptsetup luksHeaderBackup "$part" --header-backup-file "$file"
  "${sudo[@]}" chown "$(id -u):$(id -g)" "$file"
  chmod 600 "$file"
  if [ "$("${sudo[@]}" cryptsetup luksUUID "$file")" != "$("${sudo[@]}" cryptsetup luksUUID "$part")" ]; then
    echo "$file does not match $part" >&2; exit 1
  fi
  echo "$part -> $file"
  files+=("$(basename "$file")")
done

(cd "$dir" && sha256sum "${files[@]}" > "SHA256SUMS-$name" && sha256sum -c --quiet "SHA256SUMS-$name")
echo "checksums: $dir/SHA256SUMS-$name"
