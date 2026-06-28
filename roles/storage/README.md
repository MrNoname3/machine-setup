# storage role — secondary encrypted data HDD

Manages auto-unlock + automount for the 500 GB HGST HDD (LUKS2 + ext4),
mounted at `/mnt/hdd`. The disk auto-unlocks at boot using a root-local keyfile
(`/etc/luks/hdd.key`), with a passphrase slot as a manual fallback.

The Ansible role is **non-destructive**: it only ensures the keyfile
permissions, the `crypttab` auto-unlock entry, the mountpoint, and the `fstab`
line. It never partitions or formats the disk.

## One-time manual bootstrap (DESTRUCTIVE — erases the target disk)

Do this once on a fresh disk, then enable the role. Replace `/dev/sdX` with the
**data** disk (verify the model/serial first — never the system SSD!).

```sh
# 0. Back up any existing data off the disk FIRST and verify the copy.

# 1. New GPT + one partition spanning the disk
sudo wipefs -a /dev/sdX
sudo parted -s -a optimal /dev/sdX mklabel gpt
sudo parted -s -a optimal /dev/sdX mkpart hdd 1MiB 100%
sudo partprobe /dev/sdX

# 2. Generate the root-local keyfile (machine secret, never committed)
sudo install -d -m 700 /etc/luks
sudo dd if=/dev/urandom of=/etc/luks/hdd.key bs=4096 count=1
sudo chmod 400 /etc/luks/hdd.key

# 3. LUKS2 format (keyfile = slot 0) + ext4
sudo cryptsetup luksFormat --type luks2 --batch-mode /dev/sdX1 /etc/luks/hdd.key
sudo cryptsetup open /dev/sdX1 hdd_crypt --key-file /etc/luks/hdd.key
sudo mkfs.ext4 -L hdd /dev/mapper/hdd_crypt

# 4. Add a FALLBACK PASSPHRASE (you type it; it is not stored anywhere)
sudo cryptsetup luksAddKey /dev/sdX1 --key-file /etc/luks/hdd.key

# 5. Record the LUKS partition UUID in host_vars (luks_hdd_uuid):
sudo blkid -s UUID -o value /dev/sdX1
```

Then set `luks_hdd_uuid` in the host's `host_vars`, add `storage` to
`roles_enabled`, and run the playbook — it wires up crypttab + fstab so the disk
auto-unlocks and mounts at every boot.

## Recovery

- **Lost keyfile** (e.g. SSD reinstalled): unlock manually with the fallback
  passphrase — `sudo cryptsetup open /dev/sdX1 hdd_crypt`, then regenerate
  `/etc/luks/hdd.key`, `luksAddKey` it back, and re-run the playbook.
- **Disk missing at boot:** `nofail` lets the system boot normally without it.
