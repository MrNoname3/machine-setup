# mmiotrace-live — tracing the NVIDIA 390 driver from a live system

A Linux Mint 21.3 live ISO for recording, with the kernel's
[mmiotrace](https://docs.kernel.org/trace/mmiotrace.html), how the proprietary
NVIDIA 390 driver programs a Fermi GPU, for example the GT 520M in an old
laptop: what it writes to change clocks is what nouveau needs to learn. The
installed system on the machine is left alone.

Once the machine has booted the ISO, everything happens over SSH from another
machine. It goes onto a [Ventoy](https://www.ventoy.net/) stick, next to the
[rescue image](../rescue-usb/).

## What the image is

| | |
|---|---|
| **Base** | Linux Mint 21.3 Xfce, on Ubuntu 22.04 |
| **Kernel** | Ubuntu's latest 5.15 (`linux-generic`), which has mmiotrace built in; Ubuntu ships the 390 module prebuilt for exactly this kernel line, not for its newer ones |
| **Driver** | the 390 kernel module, X driver and GL libraries, `nvidia-settings`; no DKMS |
| **NVIDIA modules** | kept from loading, by name too ([mmiotrace.conf](overlay/etc/modprobe.d/mmiotrace.conf)); a trace starts first, then `modprobe --ignore-install nvidia`. `gpu-manager` is masked, and the display stays on the integrated GPU |
| **SSH** | root login with the public keys given to `build.sh`, from private address ranges (RFC 1918) only; no passwords |
| **Host key** | fixed, created on the first build and reused |
| **Tools** | `glmark2`, `mesa-utils`, `build-essential` and the kernel headers, for load during a trace and for building modules on the live system |
| **Boot** | the hostname is `mmiotrace`, and both boot menus start the live system after ten seconds |

All the changes are in [build.sh](build.sh), [customize.sh](customize.sh) (run
inside the image) and [overlay/](overlay/).

## Building

Everything runs as root in a throwaway Debian or Ubuntu container with this
repository mounted; nothing needs loop devices or mounts. The container needs
`curl ca-certificates xorriso squashfs-tools openssh-client`.

```
bash tools/mmiotrace-live/build.sh ~/path/to/key.pub [more.pub ...]
```

The Mint ISO is downloaded into `work/mmiotrace-live/` (`MLT_CACHE`) and
checked against the hash pinned in `build.sh`. The finished ISO, the host key
and its `known_hosts` entry land in `~/.local/state/mmiotrace-live`
(`MLT_OUT`). The host key is a private key, so that directory stays outside
the repository; when building in a container, copy it out of the container
too, and pass it back in for a rebuild that keeps the same identity.

## Using it

1. Copy the ISO onto the Ventoy stick, plug in wired network, and boot the
   stick. Pick the ISO in the Ventoy menu; it then starts by itself.
2. From the other machine:

   ```
   ssh -o HostName="$(RU_STATE=~/.local/state/mmiotrace-live tools/rescue-usb/find.sh)" mmiotrace
   ```

   [find.sh](../rescue-usb/find.sh) scans the local /24 for the host that
   presents the image's host key.

The matching `~/.ssh/config` entry:

```
Host mmiotrace
    User root
    HostKeyAlias mmiotrace
    UserKnownHostsFile ~/.local/state/mmiotrace-live/known_hosts
    IdentityFile ~/path/to/key.pub
```

`HostKeyAlias` keeps the live system's key apart from the installed system's,
which answers on the same address when DHCP hands the machine a fixed one.

## Tracing the clock changes

[trace-clocks.sh](trace-clocks.sh) records one cycle: the driver loading, a
second X server coming up on the NVIDIA GPU alone
([xorg-nvidia.conf](xorg-nvidia.conf), no display and no input devices), the
GPU settling to its lowest performance level, `glmark2` driving it to the
highest, and back down again. Each step and each level change lands in the
trace as a `MARK` line.

```
scp tools/mmiotrace-live/trace-clocks.sh tools/mmiotrace-live/xorg-nvidia.conf mmiotrace:
ssh mmiotrace 'setsid ./trace-clocks.sh clocks.mmio >clocks.log 2>&1 </dev/null &'
```

It refuses to start once the driver is loaded, since mmiotrace sees only the
mappings made after it starts. While it records, mmiotrace takes all but one
CPU offline, so the machine answers slowly. The registers are the 16 MiB
mapping of BAR0; `UNKNOWN` lines fall on the VRAM apertures.

## What the stick is worth to someone else

As with the rescue image: whoever holds one of the authorised private keys gets
root on any machine running it on a private network, and anyone who copies the
ISO can impersonate its host key. Rebuild with a new host key (delete the old
one first) if the stick goes missing.
