#!/bin/sh
#
# Runs inside the live root file system, from build.sh.
#
set -eu
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

# /dev/null is a plain root-owned file in this chroot, which apt's unprivileged
# _apt user cannot write to.
apt() { apt-get -o APT::Sandbox::User=root "$@"; }

apt update
# linux-generic and the nvidia-390 metapackage follow the same kernel release.
apt install -y --no-install-recommends \
  linux-generic linux-modules-nvidia-390-generic \
  nvidia-utils-390 xserver-xorg-video-nvidia-390 libnvidia-gl-390 nvidia-settings \
  openssh-server glmark2 mesa-utils build-essential

kmod=$(dpkg-query -W -f='${Depends}' linux-modules-nvidia-390-generic |
  grep -o 'linux-modules-nvidia-390-[0-9][^ ,]*-generic')
kver=${kmod#linux-modules-nvidia-390-}
[ -f "/lib/modules/$kver/kernel/nvidia-390/nvidia.ko" ] || {
  echo "customize.sh: no nvidia-390 module for $kver" >&2; exit 1; }
grep -qx 'CONFIG_MMIOTRACE=y' "/boot/config-$kver" || {
  echo "customize.sh: $kver is built without mmiotrace" >&2; exit 1; }

# Only the kernel the module was built for stays.
old=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' \
    'linux-image-[0-9]*' 'linux-modules-[0-9]*' 'linux-modules-extra-[0-9]*' \
    'linux-headers-[0-9]*' |
  awk -v keep="${kver%-generic}" '$1 == "ii" && index($2, keep) == 0 { print $2 }')
# shellcheck disable=SC2086 # one argument per package, on purpose
[ -z "$old" ] || apt purge -y $old

# It would set up the X server for the NVIDIA card at boot.
systemctl mask gpu-manager.service

# Only the host key build.sh put in place.
rm -f /etc/ssh/ssh_host_rsa_key* /etc/ssh/ssh_host_ecdsa_key*

# The initramfs carries modprobe.d, which the overlay changed.
update-initramfs -u -k "$kver"

apt clean
rm -rf /var/lib/apt/lists/*
