# mmiotrace-live — tracing the NVIDIA 390 driver from a live system

A Linux Mint 21.3 live ISO for recording, with the kernel's
[mmiotrace](https://docs.kernel.org/trace/mmiotrace.html), how the proprietary
NVIDIA 390 driver programs a Fermi GPU, for example the GT 520M in an old
laptop: what it writes to change clocks is what nouveau needs to learn. The
installed system on the machine is left alone.

Once the machine has booted the ISO, everything happens over SSH from another
machine. It goes onto a [Ventoy](https://www.ventoy.net/) stick, like the
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

### Trying the ISO in QEMU

Before it goes onto a stick, the ISO boots in QEMU without KVM, slowly but far
enough to show that the system comes up and SSH answers with the baked-in host
key and refuses a login without one. With `casper/vmlinuz` and
`casper/initrd.lz` extracted from it (`xorriso -osirrox on -indev <iso>
-extract ...`):

```
qemu-system-x86_64 -m 4096 -smp 2 -cdrom <iso> -kernel vmlinuz -initrd initrd.lz \
  -append "boot=casper username=mint hostname=mmiotrace console=ttyS0 systemd.unit=multi-user.target --" \
  -nographic -serial file:serial.log -monitor none \
  -netdev user,id=n,hostfwd=tcp:127.0.0.1:2222-:22 -device e1000,netdev=n
ssh-keyscan -p 2222 127.0.0.1 | ssh-keygen -lf -
```

## Using it

1. Copy the ISO onto the Ventoy stick, plug in wired network, and boot the
   stick. Pick the ISO in the Ventoy menu; it then starts by itself. On a
   stick of its own, a `ventoy/ventoy.json` that makes it the default image
   needs no key press at all:

   ```
   { "control": [
       { "VTOY_MENU_TIMEOUT": "5" },
       { "VTOY_DEFAULT_IMAGE": "/linuxmint-21.3-xfce-mmiotrace.iso" },
       { "VTOY_SECONDARY_TIMEOUT": "5" } ] }
   ```
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

## Reading a trace

Each line is one event:

| Line | Fields |
|---|---|
| `MAP` | timestamp, map id, physical address, virtual address, length |
| `R`, `W` | access width, timestamp, map id, physical address, value |
| `UNKNOWN` | timestamp, map id, physical address, instruction bytes |
| `MARK` | timestamp, text written to `trace_marker` |

BAR0 is the `MAP` line whose length is `0x1000000`; register offsets are the
physical addresses minus its base. A level change happens *before* the `MARK`
that reports it, because the script notices the new level afterwards: the
writes of one change lie between the previous `MARK` and that one.
[gf108/lastval.awk](gf108/lastval.awk) gives the last value of each register up
to a `MARK`, and comparing two of those is the quickest way to see what a
change touched.

mmiotrace sees what the CPU does. Work the GPU's own microcontrollers do, such
as the PMU, shows only as the data the driver uploads to them, through their
data memory ports; [gf108/pmu-scripts.py](gf108/pmu-scripts.py) pulls such
uploads apart.

Many values in a trace come from the VBIOS tables, which nouveau reads too.
[nvbios.sh](nvbios.sh) decodes a VBIOS with envytools' `nvbios`, built from a
pinned commit, as root in a throwaway container; nouveau exposes the GPU's
VBIOS as `/sys/kernel/debug/dri/<n>/vbios.rom`. A VBIOS is the board maker's
firmware, so it stays out of the repository.

## Pitfalls

- **Something else loads the driver.** The X server on the integrated GPU
  probes every EGL vendor library, and NVIDIA's loads its kernel module by name,
  which a blacklist does not stop; [mmiotrace.conf](overlay/etc/modprobe.d/mmiotrace.conf)
  refuses it with an `install` line. Check `/proc/modules` before a trace.
- **One driver after another.** Unloading the proprietary driver leaves the GPU
  in a state its boot code does not expect: nouveau loaded after it saw a
  different memory clock and soon hung. Reboot between drivers when the result
  has to mean anything.
- **The live system keeps nothing.** It runs from RAM; copy traces, built
  modules and notes off it, and stream a trace over SSH
  (`ssh mmiotrace cat /sys/kernel/tracing/trace_pipe >file`) when the experiment
  may hang the machine.
- **Raw traces identify the machine.** The driver uploads the GPU's unique ID
  to the PMU when it starts, and it ends up in the trace. Publish what is
  decoded from a trace, never the trace.
- **Rebooting a BIOS machine.** There is no way to ask it for the USB stick on
  the next boot from software; put USB first in the firmware's boot order, or
  be at the machine.

## What the stick is worth to someone else

As with the rescue image: whoever holds one of the authorised private keys gets
root on any machine running it on a private network, and anyone who copies the
ISO can impersonate its host key. Rebuild with a new host key (delete the old
one first) if the stick goes missing.

## Poking registers

[nvreg.c](nvreg.c) reads and writes GPU registers through BAR0 with aligned
32-bit accesses, one command at a time or as a script on stdin; build it on the
live system with `gcc -O2 -o /usr/local/sbin/nvreg nvreg.c`. What the traces
showed about the GT 520M, and the scripts that replay it, are in [gf108/](gf108/).
