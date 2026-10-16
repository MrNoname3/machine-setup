#!/bin/sh
#
# Runs inside the live root file system, from build.sh, with MLT_DRIVER set.
#
set -eu
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

apt-get update
case $MLT_DRIVER in
  390)
    # linux-generic and the nvidia-390 metapackage follow the same kernel release.
    apt-get install -y --no-install-recommends \
      linux-generic linux-modules-nvidia-390-generic \
      nvidia-utils-390 xserver-xorg-video-nvidia-390 libnvidia-gl-390 nvidia-settings \
      openssh-server glmark2 mesa-utils build-essential
    kmod=$(dpkg-query -W -f='${Depends}' linux-modules-nvidia-390-generic |
      grep -o 'linux-modules-nvidia-390-[0-9][^ ,]*-generic')
    kver=${kmod#linux-modules-nvidia-390-}
    ;;
  340)
    # Ubuntu ships the 340 module only as DKMS source, which builds for every
    # kernel whose headers are installed.
    apt-get install -y --no-install-recommends \
      linux-generic linux-headers-generic nvidia-340 nvidia-settings \
      openssh-server glmark2 glmark2-drm glmark2-es2-drm mesa-utils build-essential
    kimg=$(dpkg-query -W -f='${Depends}' linux-image-generic |
      grep -o 'linux-image-[0-9][^ ,]*-generic')
    kver=${kimg#linux-image-}
    ;;
esac

[ -n "$(find "/lib/modules/$kver" -name 'nvidia.ko*')" ] || {
  echo "customize.sh: no nvidia-$MLT_DRIVER module for $kver" >&2; exit 1; }
grep -qx 'CONFIG_MMIOTRACE=y' "/boot/config-$kver" || {
  echo "customize.sh: $kver is built without mmiotrace" >&2; exit 1; }

# Only the kernel the module was built for stays.
old=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' \
    'linux-image-[0-9]*' 'linux-modules-[0-9]*' 'linux-modules-extra-[0-9]*' \
    'linux-headers-[0-9]*' |
  awk -v keep="${kver%-generic}" '$1 == "ii" && index($2, keep) == 0 { print $2 }')
# shellcheck disable=SC2086 # one argument per package, on purpose
[ -z "$old" ] || apt-get purge -y $old

if [ "$MLT_DRIVER" = 340 ]; then
  # The 340 package diverts Mesa's libGL and libEGL to its own. Links to
  # Mesa's, for running a client on nouveau: LD_LIBRARY_PATH=/opt/mesa-gl.
  mkdir -p /opt/mesa-gl
  for l in libGL.so.1 libEGL.so.1 libGLESv2.so.2; do
    ln -sf "/usr/lib/x86_64-linux-gnu/$l.distrib" "/opt/mesa-gl/$l"
  done
  # A Tesla machine usually has no second GPU for a desktop, and a desktop
  # on the card would hold it while the driver loads; the image is used
  # over SSH anyway.
  systemctl set-default multi-user.target
fi

# It would set up the X server for the NVIDIA card at boot.
systemctl mask gpu-manager.service

# Only the host key build.sh put in place.
rm -f /etc/ssh/ssh_host_rsa_key* /etc/ssh/ssh_host_ecdsa_key*

# The initramfs carries modprobe.d, which the overlay changed.
update-initramfs -u -k "$kver"

apt-get clean
rm -rf /var/lib/apt/lists/*
