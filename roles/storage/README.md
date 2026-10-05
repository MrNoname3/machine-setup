# storage role — encrypted data disks

Auto-unlock + automount for secondary data disks: LUKS2, unlocked at boot with
a root-only keyfile, with a passphrase slot as the manual fallback.

| Host | Disk | Inside LUKS | Found by | Keyfile | Mounted at |
|---|---|---|---|---|---|
| laptop-old | 500 GB HGST HDD | ext4 | `UUID=` from `luks_hdd_uuid` (local.yml) | `/etc/luks/hdd.key` | `/mnt/hdd` |
| desktop-bazzite | 2 TB Seagate HDD | btrfs | `PARTLABEL=data-crypt` | `/etc/cryptsetup-keys.d/data.key` | `/var/mnt/data` |

A host lists its disks in `storage_disks` (schema in `defaults/main.yml`). A GPT
partition label identifies a disk without a machine identifier, so it can live
in host_vars, and a reinstalled system finds the disk with no question asked.
`/etc/cryptsetup-keys.d/<name>.key` is where systemd-cryptsetup looks for a key
first; it is on the root filesystem, so it is protected once the root is
encrypted too.

The Ansible role is **non-destructive**: it only ensures the keyfile
permissions, the `crypttab` auto-unlock entry, the mountpoint, and the `fstab`
line. It never partitions or formats a disk. It needs root, so on the desktop
(no passwordless sudo) it runs only when asked:

```sh
./scripts/apply.sh desktop-bazzite --tags storage -K
```

## One-time manual bootstrap (DESTRUCTIVE — erases the target disk)

Do this once on a fresh disk, then add it to the host. Replace `/dev/sdX` with
the **data** disk (verify the model/serial with `lsblk -o NAME,SIZE,MODEL`
first — never a system disk!). Back up any existing data off the disk FIRST and
verify the copy.

### btrfs, found by partition label (desktop)

`NAME` is the mapper name (`data`), the partition is labelled `NAME-crypt`.

```sh
NAME=data
# 1. New GPT + one labelled partition spanning the disk
sudo wipefs -a /dev/sdX
sudo parted -s -a optimal /dev/sdX mklabel gpt mkpart "$NAME-crypt" 1MiB 100%
sudo udevadm settle

# 2. Root-only keyfile (machine secret, never committed)
sudo install -d -m 700 /etc/cryptsetup-keys.d
sudo dd if=/dev/urandom of=/etc/cryptsetup-keys.d/$NAME.key bs=4096 count=1
sudo chmod 400 /etc/cryptsetup-keys.d/$NAME.key

# 3. LUKS2 (keyfile = slot 0) + btrfs, root of the filesystem owned by the user
sudo cryptsetup luksFormat --type luks2 --label "$NAME" --batch-mode \
  /dev/disk/by-partlabel/$NAME-crypt /etc/cryptsetup-keys.d/$NAME.key
sudo cryptsetup open /dev/disk/by-partlabel/$NAME-crypt $NAME \
  --key-file /etc/cryptsetup-keys.d/$NAME.key
sudo mkfs.btrfs -L "$NAME" /dev/mapper/$NAME
T=$(mktemp -d) && sudo mount /dev/mapper/$NAME "$T" && sudo chown "$USER:" "$T" \
  && sudo umount "$T" && rmdir "$T"

# 4. FALLBACK PASSPHRASE — type it yourself, keep it in KeePassXC
sudo cryptsetup luksAddKey /dev/disk/by-partlabel/$NAME-crypt \
  --key-file /etc/cryptsetup-keys.d/$NAME.key

# 5. Header backup — a damaged header loses the disk whatever the keys; keep
#    the file in KeePassXC as an attachment, then delete it here
sudo cryptsetup luksHeaderBackup /dev/disk/by-partlabel/$NAME-crypt \
  --header-backup-file ~/luks-header-$NAME.img
sudo chown "$USER:" ~/luks-header-$NAME.img
```

Then add the disk to `storage_disks` in the host's host_vars, enable the role
and run it with root — it wires up crypttab + fstab so the disk unlocks and
mounts at every boot.

### ext4, found by UUID (laptop)

```sh
sudo wipefs -a /dev/sdX
sudo parted -s -a optimal /dev/sdX mklabel gpt
sudo parted -s -a optimal /dev/sdX mkpart hdd 1MiB 100%
sudo partprobe /dev/sdX

sudo install -d -m 700 /etc/luks
sudo dd if=/dev/urandom of=/etc/luks/hdd.key bs=4096 count=1
sudo chmod 400 /etc/luks/hdd.key

sudo cryptsetup luksFormat --type luks2 --batch-mode /dev/sdX1 /etc/luks/hdd.key
sudo cryptsetup open /dev/sdX1 hdd_crypt --key-file /etc/luks/hdd.key
sudo mkfs.ext4 -L hdd /dev/mapper/hdd_crypt

sudo cryptsetup luksAddKey /dev/sdX1 --key-file /etc/luks/hdd.key
sudo blkid -s UUID -o value /dev/sdX1     # -> luks_hdd_uuid in local.yml
```

## Recovery

- **Lost keyfile** (e.g. system disk reinstalled): unlock manually with the
  fallback passphrase — `sudo cryptsetup open <partition> <name>` — then
  generate a new keyfile at the path the host expects, `luksAddKey` it with the
  passphrase, and re-run the role.
- **Damaged LUKS header:** `sudo cryptsetup luksHeaderRestore <partition>
  --header-backup-file <file>` with the backup from KeePassXC.
- **Disk missing at boot:** `nofail` lets the system boot normally without it.
