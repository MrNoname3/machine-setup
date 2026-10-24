# patched-deb — Debian and Ubuntu packages with a fix of ours

[build-deb.sh](build-deb.sh) rebuilds a package from its distribution's source
with the [patches/](patches/) named after the source package, and puts the
binary packages it is asked for into an output directory:

```
build-deb.sh [--keep-version] <source-package> <binary-package>[,<binary-package>...] <out-dir>
```

The version gets `+patched.<hash>` appended, the hash covering the patches.
The same source version with the same patches therefore always builds the
same version, and a newer source version or a changed patch builds a newer
one; `build-deb.sh --suffix <source-package>` prints the suffix.

`--keep-version` builds with the archive's version instead, for a source whose
packages are also installed for another architecture, such as Mesa with
Steam's i386 libraries: only the native packages are rebuilt, and the others
keep matching their version.

A patch for one upstream version takes that version as a suffix,
`<source-package>-<name>.<version>.patch`, and replaces
`<source-package>-<name>.patch` for sources whose upstream version starts with
it; the longest matching suffix wins.

## The patches

| Source package | Patch | What it fixes |
|---|---|---|
| iwd | [iwd-psk-sha256-needs-mfp.patch](patches/iwd-psk-sha256-needs-mfp.patch) | iwd picks PSK-SHA256 on WPA2/WPA3 networks even when the Wi-Fi chip cannot do management frame protection, and the chip never associates |
| intel-vaapi-driver | [intel-vaapi-driver-export-unrendered-surface.patch](patches/intel-vaapi-driver-export-unrendered-surface.patch) | the i965 VA-API driver cannot export a surface before anything is decoded into it, so Chromium-based browsers decode video in software |
| xwayland | [xwayland-guess-compositor-gpu.patch](patches/xwayland-guess-compositor-gpu.patch), and [.23.2](patches/xwayland-guess-compositor-gpu.23.2.patch) for Ubuntu 24.04's own Xwayland | under a compositor that offers only linux-dmabuf v3 and no wl_drm, such as Muffin before 6.8 on a current Mesa, Xwayland finds no GPU and every X client renders in software; the patch takes the boot VGA device |
| muffin | [muffin-presentation-time.patch](patches/muffin-presentation-time.patch), from [linuxmint/muffin#843](https://github.com/linuxmint/muffin/pull/843) | Muffin before 6.8 has no presentation-time protocol, so Chromium paces its frames off a timer the frame callbacks keep re-phasing, and Brave drops about every eighth frame of a 30 fps video it decodes on the GPU; [muffin-mint-cinnamon-desktop.patch](patches/muffin-mint-cinnamon-desktop.patch) makes a build in the PPA link against Linux Mint's cinnamon-desktop: it drops a build dependency of the tests, which do not exist and which on Ubuntu pull in Ubuntu's older library, and requires Mint's version |
| mesa | [mesa-nv50-clear-template.patch](patches/mesa-nv50-clear-template.patch), [mesa-nvc0-clear-template.patch](patches/mesa-nvc0-clear-template.patch), [mesa-vp3-destroy-wait.patch](patches/mesa-vp3-destroy-wait.patch), [mesa-va-export-interlaced.patch](patches/mesa-va-export-interlaced.patch), [mesa-egl-wayland-guess-gpu.patch](patches/mesa-egl-wayland-guess-gpu.patch), [mesa-nv84-ring-clear.patch](patches/mesa-nv84-ring-clear.patch), [mesa-nv84-destroy-wait.patch](patches/mesa-nv84-destroy-wait.patch), [mesa-nv84-motion-vectors.patch](patches/mesa-nv84-motion-vectors.patch), [mesa-nv84-slots.patch](patches/mesa-nv84-slots.patch), [mesa-nv84-vpring-clear.patch](patches/mesa-nv84-vpring-clear.patch), [mesa-nvc0-yuv-modifiers.patch](patches/mesa-nvc0-yuv-modifiers.patch), [mesa-winsys-object-del.patch](patches/mesa-winsys-object-del.patch), for kisak's 26.2 | on a GeForce 8 or later card: nv50 and nvc0 clears of a VA surface write past it; the VP2 decoder (GeForce 8 and 9) crashes setting up its rings; objects nouveau deletes stay in the kernel, so a browser's GPU process loses H.264 on VP2; a decoder torn down mid-stream hangs the video engine; the VP2 decoder runs its two engines one after the other, too slow for 1080p30, starts a stream on a black picture when its ring reuses memory, and decodes some B frames with another picture's motion vectors; VA-API refuses to export the field-split surfaces the engines decode into, so browsers decode in software; on Fermi and later, EGL refuses the block-linear NV12 surfaces VA-API exports, and a browser decoding on the GPU shows black; and under a compositor without wl_drm, Wayland EGL finds no GPU and renders in software |

## Where it runs

- **In a throwaway container, as root**, for [tools/tablet-image](../tablet-image/):
  the script installs the build tools and build dependencies itself. The
  container's apt needs `deb-src` entries.
- **On the host itself, as a user**, from the
  [patched-debs](../../roles/patched-debs/) role: the role adds the `deb-src`
  entries and the build dependencies for the build, removes them again, and
  installs and holds every binary package of the source the host has, since
  they often require each other's exact version. It rebuilds once the archive
  carries a newer version, so the held packages keep getting the distribution's
  updates, and puts the archive's build back once the source is no longer
  listed for the host.

## The PPA

[ppa.sh](ppa.sh) builds the source packages of
[ppa:mrnoname3/machine-setup](https://launchpad.net/~mrnoname3/+archive/ubuntu/machine-setup)
on the desktop and uploads them, so that Launchpad builds the packages for
Ubuntu 24.04 and Linux Mint 22, amd64 and i386:

```
tools/patched-deb/ppa.sh source work/ppa/upload   # build the source packages
tools/patched-deb/ppa.sh upload work/ppa/upload   # sign and upload them
```

Both run in a throwaway Ubuntu 24.04 container (podman), and build the archive
versions [ppa-sources.yml](ppa-sources.yml) names. A package takes that
version with `+patched<n>` appended, `<n>` being the number of commits that
touched its patches, so a new archive version or a changed patch uploads a
newer one.

Renovate watches the archives behind ppa-sources.yml and opens a pull request,
never merged on its own, when one carries a newer version. The **PPA sources**
workflow builds the source packages for every change here, so the pull request
shows whether the patches still apply; once it is merged, `ppa.sh source` and
`upload` publish the rebuild. `ppa.sh check <out-dir>` is that build without a
container, as root on Ubuntu 24.04.

Mesa and Xwayland build against kisak's PPAs, which the PPA lists as
dependencies. Muffin builds against Linux Mint's cinnamon-desktop,
which [ppa:mrnoname3/machine-setup-build-deps](https://launchpad.net/~mrnoname3/+archive/ubuntu/machine-setup-build-deps)
carries for the build alone; no host adds that one.

The uploads are signed with the OpenPGP key
`EF66147B218C737F9D35DFC518E1A4A55AAF217D`, which lives in the desktop's
`~/.gnupg`, with its passphrase in KeePassXC; the container signs through the
host's gpg-agent.
