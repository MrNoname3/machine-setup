# keyring role — KeePassXC as the SSH agent

SSH private keys live **only inside the KeePassXC database**, which serves them
to an ssh-agent while it is unlocked. A **locked database blocks SSH** — that is
the point. On disk there are only `.pub` files, and `~/.ssh/config` points
`IdentityFile` at those (`IdentitiesOnly yes` is global), so nothing usable is
lying around.

Both hosts get the same user-visible outcome via OS-appropriate mechanisms:

| Host | KeePassXC | Agent it feeds |
|------|-----------|----------------|
| desktop (Bazzite/KDE) | flatpak | per-user systemd `ssh-agent.socket` (`SSH_AUTH_SOCK` pinned into the sandbox via a flatpak override) |
| laptop (Mint/Cinnamon) | native apt | the system's own gnome-keyring agent chain, untouched — plus one drop-in (below) |

## What the role does

- Installs KeePassXC (flatpak from Flathub / apt) and, on Mint, `ssh-askpass-gnome`.
- Ensures `~/.ssh` + `~/.ssh/control` (0700) and symlinks `~/.ssh/config` to the
  synced config in `ssh_keys_dir` (enforcing 0600).
- Generates a `.pub` for any private key still on disk (normally a no-op — the
  private keys were deleted from disk once they moved into the database).
- Seeds `keepassxc.ini` (SSH agent on, theme, tray, autostart behaviour, security
  timeouts) and drops an XDG autostart entry.
- Deploys the Brave native-messaging manifest so KeePassXC browser integration
  works (only the proxy `path` differs per OS).
- **Bazzite:** enables the user `ssh-agent.socket` and pins `SSH_AUTH_SOCK` +
  the socket into the KeePassXC flatpak via `flatpak override`.
- **Mint:** installs a single user-level systemd drop-in on
  `gnome-keyring-daemon.service` (`ssh-askpass.conf`) that gives gnome-keyring's
  internal OpenSSH agent an askpass + DISPLAY. Without it, keys marked "require
  user confirmation" fail with `agent refused operation` — the agent has no way
  to show the dialog. No `SSH_AUTH_SOCK` override anywhere; the stock session
  value is used on both OSes.

## Manual one-time steps (the GUI owns the secrets)

The role cannot touch the database. Once per database (the settings travel with
the synced `.kdbx`, so a second machine inherits them):

1. Open KeePassXC → **Settings → SSH Agent → Enable SSH Agent integration**
   (verify it is ticked even though the ini is seeded — the GUI is authoritative).
2. For every SSH key entry:
   - attach the **private key file** to the entry (*Advanced → Attachments*);
   - on the entry's **SSH Agent tab**: select that attachment, tick **Add key to
     agent when database is opened/unlocked** and **Remove key from agent when
     database is closed/locked**.
3. Unlock the database and check: `ssh-add -l` should list the keys.

### "Require user confirmation" keys

Ticking that option on an entry means a dialog on **every** signature
(`ssh-add -c` semantics — there is no "cache for N minutes"). Two consequences:

- `~/.ssh/config` uses connection multiplexing (`ControlMaster auto`,
  `ControlPersist`), so one interactive confirm covers the follow-up commands on
  the same host until the master idles out.
- Unattended/scripted SSH (CI, an AI assistant, cron) **will hang** waiting for
  the click — `BatchMode` does not suppress the dialog. Leave confirmation OFF
  for keys used unattended; the locked-database gate is the real protection.

## Troubleshooting

- `agent refused operation` (Mint): the drop-in isn't active yet — it takes
  effect at the next login (the agent child spawns lazily); re-log and retry.
- KeePassXC (flatpak) says it can't connect to the agent: check
  `flatpak override --user --show org.keepassxc.KeePassXC` shows the
  `SSH_AUTH_SOCK` env + socket filesystem grant, then restart KeePassXC.
- `Permission denied (publickey)` everywhere: the database is locked. That is
  the designed behaviour — unlock it.

## Secrets policy

Private keys exist only in the `.kdbx` (synced + offline backup tarballs).
Nothing in this role or repo contains key material; the `[KeeShare]` section of
`keepassxc.ini` is deliberately not reproduced (per-install private key).
