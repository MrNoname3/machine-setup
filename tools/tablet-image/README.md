# tablet-image — Debian with Phosh for Bay Trail tablets

Builds a disk image of Debian 13 with the [Phosh](https://phosh.mobi/) touch
shell for tablets with an Intel Atom "Bay Trail" CPU: a 64-bit system behind
32-bit UEFI firmware. The image goes onto an SD card or the internal eMMC as it
is and grows its root file system to the device on first boot.

Machine-specific fixes live in profiles under [machines/](machines/). The one
there is the Lenovo Miix 2 8, where with the profile applied the display,
touch, rotation, sound, Wi-Fi, Bluetooth and both cameras work.

## What the image is

| | |
|---|---|
| **Boot** | IA32 and x64 GRUB on the ESP, both loading the kernel through Debian's `/vmlinuz` links, so kernel updates never touch the ESP |
| **Shell** | Phosh with Firefox ESR, Foliate (e-books), Celluloid (video); the user logs in automatically and the screen lock starts out off |
| **Network** | NetworkManager with iwd; Wi-Fi is joined on the touch screen |
| **SSH** | the user logs in with the public keys given to `build.sh` and has sudo without a password; no root login, no passwords; each machine creates its own host keys on first boot |
| **Updates** | unattended security updates; DKMS rebuilds the profile's modules for new kernels, and `dkms-check` puts up a notification when one did not build (after a package run and at boot) |

## Building

Everything runs as root in a throwaway Debian 13 container with this repository
mounted; nothing needs loop devices. The container needs `mmdebstrap
e2fsprogs dosfstools mtools fdisk grub-efi-ia32-bin grub-efi-amd64-bin
acpica-tools git`, and `deb-src` entries for `build-deb.sh`.

```
bash tools/tablet-image/build-deb.sh iwd iwd                  # once: patched iwd
bash tools/tablet-image/build-deb.sh intel-vaapi-driver i965-va-driver  # and VA-API driver
TI_MACHINE=miix2-8 bash tools/tablet-image/build-atomisp.sh   # once: camera driver
TI_USER=miix TI_HOSTNAME=tablet TI_MACHINE=miix2-8 TI_FIRMWARE=<dir> \
  bash tools/tablet-image/build.sh ~/path/to/key.pub
```

The results land in `work/tablet/` (`TI_OUT`); the header of each script lists
its settings. Write `tablet-debian13-phosh.img` to the card or eMMC with `dd`,
identifying the target by size and model.

- **`build-deb.sh`** builds a Debian package with the
  [patches/](patches/) named after its source package; build.sh installs it
  and holds it there.
  - [iwd](patches/iwd-psk-sha256-needs-mfp.patch): without it iwd picks
    PSK-SHA256 on WPA2/WPA3 networks even when the Wi-Fi chip cannot do
    management frame protection, and the chip never associates.
  - [intel-vaapi-driver](patches/intel-vaapi-driver-export-unrendered-surface.patch):
    the i965 driver could not export a surface before anything was decoded
    into it, so Chromium-based browsers fell back to decoding video in
    software.
- **`build-atomisp.sh`** prepares the atomisp camera driver, which Debian does
  not ship, as a DKMS source: the staging driver of the kernel release the
  profile names, with the profile's `atomisp/*.patch` applied.

## Hardware video decoding

Bay Trail decodes H.264, MPEG-2 and VC-1 through VA-API (the i965 driver), not
VP9, AV1 or HEVC. Firefox and Celluloid use it as the image sets them up.
Chromium-based browsers need the patched driver from `build-deb.sh` and their
VA-API features switched on, for example:

```
--enable-features=AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,VaapiIgnoreDriverChecks
```

Chromium renames these features from time to time, and then decodes in
software without saying so. To check, play a video, open
`chrome://media-internals` (`brave://media-internals` in Brave), select the
playing player and read **kVideoDecoderName**: `VaapiVideoDecoder` with
**kIsPlatformVideoDecoder** `true` is the hardware decoder, `FFmpegVideoDecoder`
is software. The "Video Decode" line of `chrome://gpu` reports what the
browser could use, not what a video gets.

## Machine profiles

A profile is a directory under `machines/` with:

| | |
|---|---|
| `machine.conf` | the VBT, firmware files, extra packages and kernel parameters, and `ATOMISP_TAG` for `build-atomisp.sh` |
| `overlay/` | files laid over the root file system |
| `dkms/` | module sources, built for every installed kernel |
| `acpi/*.asl` | tables the kernel loads over the firmware's, through an early cpio in the initramfs |
| `atomisp/*.patch` | patches for the atomisp driver |

Firmware files are named in `machine.conf` and read from `TI_FIRMWARE`. Most
are not redistributable, so they stay out of the repository.

## Lenovo Miix 2 8

### Firmware files

| File | Where from |
|---|---|
| `miix2-8-vbt-217.bin` | the Video BIOS Table the firmware's GOP uses for the panel. Unpack the BIOS update `zijh0110.exe` from Lenovo with 7-Zip, open the image with UEFIExtract and take the `IntelGopVbt` section numbered 217 |
| `BCM4324B3_002.004.006.0130.0138.hcd` | the Bluetooth patch file from the Windows installation (`Windows/System32/drivers`) |
| `shisp_2400b0_v21.bin` | the ISP firmware, from [linux-firmware](https://gitlab.com/kernel-firmware/linux-firmware) `intel/ipu/` |

### What the profile fixes

- **Display**: i915 gets the VBT the firmware withholds; the Crystal Cove
  PMIC's GPIO driver, which Debian does not build, comes in through DKMS and
  loads before i915; `vlv-dsi-fastset-prep` lets i915 take over the firmware's
  mode, because a full modeset of the DSI panel hangs the machine.
- **Wi-Fi**: management frame protection is off in brcmfmac (the 2013
  firmware rejects it); with the patched iwd, WPA2 and WPA2/WPA3 transition
  networks work, WPA3-only networks do not.
- **Cameras**: atomisp with [two patches](machines/miix2-8/atomisp/); the
  front sensor runs its own exposure control, the rear one starts at a fixed
  gain (`70-ov5693-gain.rules`). The rear sensor often does not answer its
  first probe at boot, and atomisp then registers neither camera;
  `miix-rear-camera-probe` probes it again.
- **Touchscreen**: it also runs from the cameras' power rails, which
  [tcs0-power.asl](machines/miix2-8/acpi/tcs0-power.asl) keeps up; the PMIC
  GPIO driver loads from the initramfs, because the touchscreen's ACPI
  power-up sequence switches one of its pins. The cameras themselves are only
  powered while in use (their LED flashes once each at boot, when the drivers
  probe them).
- **Phantom ports**: i915's DisplayPort and HDMI ports are switched off on the
  kernel command line.

### One step in the firmware setup

atomisp only finds the camera ISP if the firmware exposes it as PCI device
00:03.0. The Lenovo setup menu hides that option, so it is set from Linux once:

```
sudo miix-isp-pci-mode linux     # then reboot
```

It refuses to write unless the model, BIOS version and variable layout are the
ones it knows. The Windows camera needs the factory setting back
(`miix-isp-pci-mode windows`), as does a restored Windows installation.

### Known limits

- The rear camera's picture is mirrored: its driver's flip controls stall the
  stream on atomisp.
- Neither camera has autofocus or automatic white balance; the white balance
  is fixed for indoor light.
- Only one camera can be open at a time, and it is selected per device open
  (V4L2 input 0 is the front camera, which is what PipeWire offers).
