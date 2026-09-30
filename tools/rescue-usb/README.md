# rescue-usb — a live system that can be driven over SSH

A [SystemRescue](https://www.system-rescue.org/) image customised so that,
once a machine has booted it, everything else happens over SSH from another
machine: data recovery, disk and hardware inspection, file system repair. Nobody
has to type anything on the machine being rescued.

It goes onto a [Ventoy](https://www.ventoy.net/) stick next to a Memtest86+
image, so one stick covers normal PCs and tablets with 32-bit UEFI firmware.

## What the image does differently

| | |
|---|---|
| **SSH** | root login with the public keys given to `build.sh`, and nothing else: password login is off |
| **Host key** | fixed, created on the first build and reused, so the client can verify it is talking to this stick and not to whatever else answers on that address |
| **Firewall** | SystemRescue's default rule set, plus SSH from private address ranges (RFC 1918) |
| **32-bit UEFI** | an IA32 GRUB loader, so a 64-bit CPU behind 32-bit firmware (Bay Trail tablets such as the Lenovo Miix 2) can boot the 64-bit kernel |
| **Console** | keyboard layout and time zone from [500-remote.yaml](recipe/iso_add/sysrescue.d/500-remote.yaml), and on laptops with two GPUs it goes to the one driving the built-in panel (otherwise it can land on the other GPU and the screen stays dark) |

Everything else is stock SystemRescue. All the changes live in [recipe/](recipe/),
which `sysrescue-customize` applies to the downloaded ISO.

## Building

The build downloads SystemRescue and Memtest86+ into `~/.cache/rescue-usb`,
verifies them, and writes the finished stick contents to
`~/.local/state/rescue-usb/stick`. SystemRescue is checked against its author's
signing key, and Memtest86+ against the hashes pinned in `build.sh`.

It needs `curl gpg xorriso squashfs-tools rsync patch mtools unzip
openssh-client` and the IA32 GRUB modules (`grub-efi-ia32-bin` on Debian and
Ubuntu). None of that has to be on the host: a throwaway Ubuntu container is
enough.

```
./build.sh ~/path/to/key.pub [more.pub ...]
```

Every public key in the given files may log in as root. The host key
(`~/.local/state/rescue-usb/ssh_host_ed25519_key`) is what makes the stick
recognisable, so keep a copy of it. If you lose it, the next build creates a
new one and the old stick no longer matches `known_hosts`.

To move to a newer release, change `SR_VERSION`, or `MT_VERSION` together with
its two pinned hashes, and rebuild.

## Making the stick

This step erases the stick, so it is done by hand:

1. Download Ventoy for Linux from its releases page and check the published
   SHA-256.
2. `sudo ./Ventoy2Disk.sh -i /dev/sdX`. Identify the stick by its size and
   model (`lsblk -o NAME,SIZE,MODEL`), never by guessing the letter.
3. Copy the contents of `~/.local/state/rescue-usb/stick/` onto the large
   partition Ventoy created. This includes `ventoy/ventoy.json`, which replaces
   any Ventoy configuration already on the stick.

After a rebuild, only step 3 is needed.

## Using it

1. Plug in the stick and wired network, and boot from the stick. Nothing has
   to be selected: Ventoy starts the rescue image when its menu times out
   (the timeouts `build.sh` writes into `ventoy/ventoy.json`), and
   SystemRescue's own menu then starts its default entry the same way.
   Pressing a key in either menu stops the countdown, for example to pick
   Memtest86+.
2. From the other machine:

   ```
   ssh -o HostName="$(./find.sh)" rescue
   ```

   `find.sh` scans the local /24 for the host presenting the stick's host
   key. The address is not fixed, because it comes from whatever DHCP server
   the network has.

The matching `~/.ssh/config` entry:

```
Host rescue
    User root
    HostKeyAlias rescue
    UserKnownHostsFile ~/.local/state/rescue-usb/known_hosts
    IdentityFile ~/path/to/key.pub
```

## Memory testing

Memtest86+ runs instead of an operating system, so it has no network and cannot
be driven over SSH. Someone has to start it from a boot menu and read the
result off the screen.

| Firmware | Where |
|---|---|
| 64-bit UEFI | SystemRescue menu → *Memtest86+ memory tester for UEFI* |
| 32-bit UEFI | SystemRescue menu → *Memtest86+ memory tester for 32-bit UEFI*, or the `memtest86+-…-i586.iso` in the Ventoy menu |
| BIOS | SystemRescue menu, or the `memtest86+-…-i586.iso` |

Over SSH, `memtester` can exercise the memory the running system is not using.
It is a quick check, not a replacement for a full Memtest86+ run.

## 32-bit UEFI tablets

- Secure Boot has to be off. The IA32 loader is not signed.
- Ventoy supports IA32 UEFI. The image carries `bootia32.efi` both in its
  file system and in its El Torito EFI image, which is where firmware looks
  when the ISO is written to a stick directly.
- Through Ventoy, the IA32 path only boots when all memory sits below 4 GB,
  which is the case for 2 GB tablets. With memory above that line, the boot
  stalls after the SystemRescue menu. The same ISO written directly to a
  stick (`dd`) boots either way.
- Tablets like these often have a single micro-USB port. The stick and the
  Ethernet adapter then need an OTG hub. Alternatively, boot the *copy system
  to RAM* entry, then swap the stick for the adapter. That entry holds the
  whole system image in memory, which leaves a 2 GB tablet little room for
  anything else.

## What the stick is worth to someone else

Whoever holds one of the authorised private keys gets root on any machine
running this stick on a private network. The stick itself carries the host key,
so anyone who copies it can impersonate it, although they cannot log in with
it. Keep the stick like a key, and rebuild with a new host key (delete the old
one first) if it goes missing.
