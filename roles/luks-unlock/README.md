# luks-unlock role — remote root unlock at boot (dropbear)

The laptop's root disk is LUKS-encrypted, so after power-on it sits at the
passphrase prompt. This role puts a tiny SSH server (**dropbear**) into the
initramfs so the passphrase can be typed **remotely** — useful when the machine
is docked somewhere headless.

The unlock still requires the LUKS passphrase every time; this role only adds a
remote way to enter it. Only the **public** key lives in this repo
(`files/laptop.pub`).

## What the role does

- Installs `dropbear-initramfs` and authorizes the unlock SSH key for it.
- Force-loads the USB-ethernet drivers (`usbnet`, `ax88179_178a`) early in the
  initramfs — the dock's USB NIC takes ~6 s to link up, and DHCP must not race it.
- Sets `ip=dhcp` on the kernel command line (the documented dropbear-initramfs
  method) and rebuilds the initramfs/grub via handlers.

External dependency (values not in this repo): a **DHCP reservation on the
router** pins the machine's address, so the initramfs and the booted system get
the same, known IP.

## Unlocking remotely

1. Power the machine on and give it ~15 s to reach the initramfs + DHCP.
2. SSH in as **root** — dropbear listens on the **default port 22** in the
   initramfs (this is *not* the hardened port of the booted system's sshd; that
   one only exists after boot):

   ```sh
   ssh root@<laptop-address>        # or a dedicated ssh-config alias
   ```

3. At the BusyBox prompt run:

   ```sh
   cryptroot-unlock
   ```

   type the LUKS passphrase, the initramfs continues booting, and the SSH
   session drops.

### Host-key warning

The initramfs has its **own** dropbear host key, different from the booted
system's OpenSSH key — same address, two identities. Keep a dedicated ssh-config
alias for the unlock (separate `known_hosts` entry / port 22 vs the hardened
port), otherwise ssh will scream about a changed host key every time you switch
between the two.

## Scope notes

- Wired ethernet only — Wi-Fi in an initramfs is not practical.
- The secondary data HDD is **not** this role's job: it auto-unlocks *after*
  root is open, via a keyfile on the encrypted root (see `roles/storage/`).
- A home-only pendrive-keyfile unlock for the root (crypttab `passdev`
  keyscript) was considered and is parked — passphrase + dropbear cover the
  current needs.
