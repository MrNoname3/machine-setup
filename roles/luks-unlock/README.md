# luks-unlock role — remote root unlock at boot (dropbear)

A Mint host's root disk is LUKS-encrypted, so after power-on it sits at the
passphrase prompt. This role puts a tiny SSH server (**dropbear**) into the
initramfs so the passphrase can be typed **remotely** — useful when the machine
runs headless.

The unlock still requires the LUKS passphrase every time; this role only adds a
remote way to enter it. Only the **public** key lives in this repo: the host's
`ssh_authorized_key_file` under `files/`, the same key the `ssh-access` role
authorizes.

## What the role does

- Installs `dropbear-initramfs` and authorizes the unlock SSH key for it.
- Sets `ip=dhcp` on the kernel command line (the documented dropbear-initramfs
  method) and rebuilds the initramfs/grub via handlers. The NIC driver needs no
  special handling — the stock initramfs (`MODULES=most`) already carries it.
- Cleans up a legacy force-load of USB-ethernet drivers left over from an
  adapter that is no longer part of the machine.

External dependency (values not in this repo): a **DHCP reservation on the
router** pins the machine's address, so the initramfs and the booted system get
the same, known IP.

## Unlocking remotely

1. Power the machine on and give it ~15 s to reach the initramfs + DHCP.
2. SSH in as **root** — dropbear listens on the **default port 22** in the
   initramfs (this is *not* the hardened port of the booted system's sshd; that
   one only exists after boot):

   ```sh
   ssh root@<machine-address>       # or the machine's own alias, see below
   ```

3. At the BusyBox prompt run:

   ```sh
   cryptroot-unlock
   ```

   type the LUKS passphrase, the initramfs continues booting, and the SSH
   session drops.

### One ssh name for both

The initramfs has its **own** dropbear host key, different from the booted
system's OpenSSH key — same address, two identities. A `Match` block can send
the machine's usual alias to dropbear whenever port 22 answers, which only
happens while the initramfs waits. The two keys stay apart on their own, since
`known_hosts` records a non-default port with the address:

```sshconfig
Match originalhost <alias> exec "timeout 0.5 bash -c '</dev/tcp/%h/22' 2>/dev/null"
    Port 22
    User root
    RequestTTY yes
    RemoteCommand cryptroot-unlock

Host <alias>
    HostName <machine-address>
    Port <hardened-port>
```

The `Match` block goes above the `Host` block, as ssh keeps the first value it
reads. `ssh <alias>` then asks for the passphrase at boot and logs in otherwise. To
run another command in the initramfs, override the unlock:
`ssh -o RemoteCommand=none <alias> '…'`.

## Scope notes

- Wired ethernet only — Wi-Fi in an initramfs is not practical.
- The secondary data HDD is **not** this role's job: it auto-unlocks *after*
  root is open, via a keyfile on the encrypted root (see `roles/storage/`).
- A home-only pendrive-keyfile unlock for the root (crypttab `passdev`
  keyscript) was considered and is parked — passphrase + dropbear cover the
  current needs.
