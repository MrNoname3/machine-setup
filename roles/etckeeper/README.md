# etckeeper role — version-control /etc with git

Puts the whole `/etc` directory under **git**, so every change is tracked and
recoverable. Mirrors the "everything reproducible" philosophy of this repo, but
for the bits that aren't expressed as Ansible (manual tweaks, package postinst
edits, GUI-written config).

## What the role does

- Installs `etckeeper` + `git`.
- Sets `VCS="git"` and keeps daily autocommits on in
  `/etc/etckeeper/etckeeper.conf`.
- Runs `etckeeper init` once (creates `/etc/.git`).
- Commits the current state of `/etc` (only when there are uncommitted changes,
  so re-runs stay idempotent / `changed=0`).

Installing the package also wires up the **apt hooks** automatically
(`/etc/apt/apt.conf.d/05etckeeper`, `99etckeeper`): `/etc` is committed
**before and after every package operation**, plus a **daily autocommit**
(systemd `etckeeper.timer`). No manual commits needed for normal use.

## SECURITY — the repo is local and secret-bearing

`/etc/.git` is **root-only** (`0700`) and lives only on the laptop. It captures
files that contain secrets:

- `/etc/shadow`, `/etc/gshadow`
- `/etc/luks/hdd.key` (the HDD auto-unlock keyfile)
- WireGuard private keys under `/etc/NetworkManager/system-connections/`

**It is never pushed.** `PUSH_REMOTE` is left empty on purpose. Do **not** point
etckeeper at the Gitea repo (which is anonymous-readable) or any other remote.
This is for local history/rollback only.

## Everyday use

```sh
# history
sudo etckeeper vcs log --oneline | head
cd /etc && sudo git log -p resolv.conf      # what changed in one file

# manual snapshot (e.g. before hand-editing something risky)
sudo etckeeper commit "before tweaking sshd_config"

# see what's currently uncommitted
sudo etckeeper vcs status

# undo a change to a single file (restore last committed version)
cd /etc && sudo git checkout -- ssh/sshd_config

# roll the whole /etc back to a past commit (careful!)
cd /etc && sudo git log --oneline
sudo git checkout <commit> -- .
```

`etckeeper vcs <cmd>` is just `git <cmd>` run inside `/etc` as root — use either.

## Notes

- Some volatile files are auto-excluded via `/etc/.gitignore` (e.g. `mtab`,
  `blkid.tab`); etckeeper manages that list.
- File ownership/permissions are preserved by etckeeper's metadata store
  (`/etc/.etckeeper`), since git itself doesn't track them.
