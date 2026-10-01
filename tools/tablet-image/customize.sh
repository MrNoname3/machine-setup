#!/bin/sh
# Runs inside the new root file system, after every package is installed.
set -eu

# The overlay's deb822 list, with updates and security, replaces this one.
rm -f /etc/apt/sources.list

echo "$TI_HOSTNAME" >/etc/hostname
printf '127.0.1.1\t%s\n' "$TI_HOSTNAME" >>/etc/hosts

sed -i 's/^# *\(hu_HU.UTF-8 UTF-8\)/\1/; s/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen >/dev/null
echo 'LANG=hu_HU.UTF-8' >/etc/default/locale
ln -sf /usr/share/zoneinfo/Europe/Budapest /etc/localtime
echo Europe/Budapest >/etc/timezone
sed -i 's/^XKBLAYOUT=.*/XKBLAYOUT="hu"/' /etc/default/keyboard

# UID 1000 is the account phosh.service logs in. Its password stays locked
# until one is set over SSH; the screen lock is off until then, and sudo asks
# for no password.
useradd -m -u 1000 -s /bin/bash -G sudo,audio,video,input,netdev,render "$TI_USER"
install -d -m 700 -o "$TI_USER" -g "$TI_USER" "/home/$TI_USER/.ssh"
install -m 600 -o "$TI_USER" -g "$TI_USER" /tmp/authorized_keys "/home/$TI_USER/.ssh/authorized_keys"
rm /tmp/authorized_keys
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$TI_USER" >"/etc/sudoers.d/90-$TI_USER-nopasswd"
chmod 440 "/etc/sudoers.d/90-$TI_USER-nopasswd"

dconf update

# Every machine gets its own identity; both are recreated on first boot.
rm -f /etc/ssh/ssh_host_*
: >/etc/machine-id

# Locally built packages (build-iwd.sh) replace the archive's; the hold keeps
# an archive update from taking the patch back out.
if [ -d /tmp/debs ]; then
  dpkg -i /tmp/debs/*.deb >/dev/null
  for d in /tmp/debs/*.deb; do apt-mark hold "$(dpkg-deb -f "$d" Package)" >/dev/null; done
  rm -rf /tmp/debs
fi

# firefox-esr-mobile-config sets a desktop user agent with "Mobile;" added,
# which Google search rejects as an unsupported browser; its own per-site
# rules still apply on top of Firefox's regular user agent. The rest trims
# what Firefox does at start on a slow CPU: fewer content processes, no
# preloaded tab or spare process, no local AI features. Without VP9 and AV1,
# which Bay Trail decodes only in software, YouTube sends H.264, which VA-API
# decodes.
if [ -f /etc/firefox/policies/policies.json ]; then
  python3 - <<'EOF'
import json
p = "/etc/firefox/policies/policies.json"
d = json.load(open(p))
pol = d["policies"]
prefs = pol.setdefault("Preferences", {})
prefs["general.useragent.override"] = {"Value": "", "Status": "locked"}
for k, v in {
    "dom.ipc.processCount": 2,
    "dom.ipc.processPrelaunch.enabled": False,
    "browser.newtab.preload": False,
    "browser.ml.enable": False,
    "browser.ml.chat.enabled": False,
    "browser.ml.linkPreview.enabled": False,
    "browser.tabs.groups.smart.enabled": False,
    "extensions.htmlaboutaddons.recommendations.enabled": False,
    "media.av1.enabled": False,
    "media.mediasource.vp9.enabled": False,
}.items():
    prefs[k] = {"Value": v, "Status": "default"}
pol.setdefault("FirefoxHome", {}).update(
    {"SponsoredTopSites": False, "SponsoredPocket": False, "Stories": False, "SponsoredStories": False})
pol.setdefault("UserMessaging", {}).update(
    {"SkipOnboarding": True, "MoreFromMozilla": False, "FirefoxLabs": False})
json.dump(d, open(p, "w"), indent=4)
EOF
fi

systemctl enable phosh.service NetworkManager.service iwd.service bluetooth.service \
  ssh.service tablet-wifi-import.service systemd-timesyncd.service >/dev/null
systemctl set-default graphical.target >/dev/null

# DKMS sources build.sh placed under /usr/src, built for every
# installed kernel; dkms rebuilds them for later kernels by itself.
for conf in /usr/src/*/dkms.conf; do
  [ -f "$conf" ] || continue
  dir=${conf%/dkms.conf}
  name=$(sed -n 's/^PACKAGE_NAME="\(.*\)"/\1/p' "$conf")
  version=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$conf")
  [ "${dir##*/}" = "$name-$version" ] || { echo "dkms: $dir is not $name-$version" >&2; exit 1; }
  dkms add -m "$name" -v "$version" >/dev/null
  for k in /usr/lib/modules/*; do
    if [ -d "$k/build" ]; then
      dkms install -m "$name" -v "$version" -k "${k##*/}" >/dev/null
    fi
  done
done

# Modules an overlay dropped under /usr/lib/modules/*/updates.
for k in /usr/lib/modules/*; do depmod -a "${k##*/}"; done

# The overlay's initramfs hooks pick up a VBT and ACPI tables supplied at
# build time.
update-initramfs -u -k all >/dev/null
