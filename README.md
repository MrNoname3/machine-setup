# machine-setup

Reproducible, version-controlled setup for my Linux machines, driven by Ansible
and run **locally** on each machine.

## Goals
- **Followable** — a written runbook for the steps that must stay manual.
- **Reproducible** — idempotent, re-runnable Ansible for everything after first boot.
- **Version-controlled** — this repo is the single source of truth.

## Secrets policy
**NEVER commit secrets** (LUKS keyfiles, passwords, KeePassXC databases, private keys).
This repo is **public on GitHub** (and served by a local Gitea), so it must contain
only *procedures and templates*. If a secret must live here, encrypt it with
`ansible-vault` or `sops`. See `.gitignore`.

## Hosts
- **laptop-old** — Intel i5-2430M (Sandy Bridge), NVIDIA GT 520M (Fermi), 8 GB RAM,
  SSD + HDD, Optimus. Runs Linux Mint (Cinnamon).
- **desktop-bazzite** — main desktop, Bazzite (immutable, rpm-ostree). Uses a different
  package model than apt; the `base` role's apt tasks are guarded and will not run here.
- **tablet-miix** — Lenovo Miix 2 8 (Atom Z3740, 2 GB RAM), Debian 13 with Phosh,
  installed from the image [tools/tablet-image](tools/tablet-image/) builds. The image
  carries the hardware support and the core apps; the playbook adds access, /etc tracking
  and the further apps.

## Repository layout
```
machine-setup/
├── README.md                    # this file — runbook + usage
├── AGENTS.md                    # instructions for coding agents (CLAUDE.md imports it)
├── bootstrap.sh                 # curl-able bootstrap (see Workflow step 2)
├── machine-setup.code-workspace # portable VS Code workspace
├── ansible.cfg                  # local-run defaults
├── inventory.ini                # hosts and groups (all use local connection)
├── requirements.txt             # pinned python toolchain (ansible-core, ansible-lint)
├── requirements.yml             # galaxy collections — both Renovate-managed
├── scripts/
│   ├── apply.sh                 # run the playbook with the repo-local toolchain
│   ├── check.sh                 # release gate (CI runs exactly this)
│   ├── ensure-venv.sh           # bootstraps .venv/ + .ansible/ (gitignored)
│   ├── luks-header-backup.sh    # LUKS header backups (see roles/storage)
│   └── sudo-askpass.sh          # sudo password from a dialog, for runs without a terminal
├── tools/                       # standalone tooling — not part of the playbook
│   ├── gpu-tune/                # measure an AMD GPU undervolt (see its README)
│   ├── mem-tune/                # measure memory latency, bandwidth, capacity
│   ├── rescue-usb/              # SystemRescue stick that is driven over SSH
│   └── tablet-image/            # Debian + Phosh disk image for Bay Trail tablets
├── work/                        # working files; in the repo, out of git (see AGENTS.md)
├── site.yml                     # maps each host to its enabled roles
├── group_vars/
│   └── all.yml                  # shared variables (primary_user, ssh_keys_dir)
├── host_vars/
│   ├── laptop-old/
│   │   ├── main.yml             # per-host settings (roles_enabled, ...)
│   │   └── local.yml            # machine identifiers — untracked; prompted+saved by site.yml
│   ├── desktop-bazzite/         # same layout (main.yml + untracked local.yml)
│   └── tablet-miix/             # same layout
└── roles/
    ├── base/            # packages (present/absent), sudo; Cinnamon defaults where base_cinnamon
    ├── ssh-access/      # hardened SSH server
    ├── printers/        # CUPS queues bound to the right driver
    ├── brave/           # browser (apt on Mint, rpm-ostree layer on Bazzite)
    ├── flatpaks/        # per-host Flatpak app set
    ├── appimages/       # Gear Lever's AppImage set + update sources
    ├── brew/            # Homebrew CLI packages (Bazzite)
    ├── git/             # global git settings
    ├── synology-drive/  # Synology Drive client
    ├── steam/           # Steam (+ flatpak on Bazzite)
    ├── lutris/          # Flatpak Lutris: game icons shared with the host
    ├── heroic/          # Heroic's default Wine: a Proton build from ProtonPlus
    ├── vscode/          # VS Code + settings + extensions + board udev rules
    ├── luks-unlock/     # remote root unlock at boot (dropbear in the initramfs)
    ├── keyring/         # KeePassXC as the SSH agent (both OSes)
    ├── kde/             # Plasma desktop tweaks (Bazzite)
    ├── phosh/           # Phosh session settings in dconf (tablet)
    ├── graphics/        # phantom VGA (laptop) + AMD undervolt profiles (Bazzite)
    ├── firewall/        # ufw
    ├── storage/         # data-disk crypttab/mount
    ├── wireguard/       # auto-VPN when away from home
    ├── containers/      # rootless Podman
    └── etckeeper/       # /etc in git (runs last)
```

## Workflow

### 1. Base install (manual — see runbook below)
The encrypted base install is interactive/destructive and is **not** scripted.
Follow the runbook section.

### 2. Bootstrap (on the freshly installed machine)

Paste this into a terminal (as your normal user — **not** root; works anywhere
with Internet — the repo is public on GitHub):

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MrNoname3/machine-setup/main/bootstrap.sh)"
```

It installs the bare minimum (git + python3-venv via apt on Mint; nothing on
Bazzite — both ship with the image), clones this repo to
`~/Projects/machine-setup`, then shows a host menu (read from `inventory.ini`,
so new machines appear automatically) and offers to run the playbook right
away. Idempotent — safe to re-run any time.

Ansible itself is **not** installed system-wide: `scripts/apply.sh` bootstraps
the pinned toolchain (`requirements.txt` + `requirements.yml`) into the
gitignored `.venv/` + `.ansible/` on first use. Deleting the repo directory
removes the whole toolchain with it.

Non-interactive variant (picks the host and runs immediately):

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MrNoname3/machine-setup/main/bootstrap.sh)" -- laptop-old
```

> The `bash -c "$(curl ...)"` form (instead of `curl | bash`) keeps stdin on the
> terminal so the menu can prompt.

At home you can clone from the local Gitea instead (it mirrors to GitHub on
every push): prefix the command with `REPO_URL=<gitea-clone-url>`.

### 3. Apply / re-apply the playbook

Always via `scripts/apply.sh` — it bootstraps/uses the repo-local toolchain and
runs `ansible-playbook -c local` with it. The host argument selects which
machine's configuration to apply (the "switch" for the multi-host repo); any
further arguments are passed straight to `ansible-playbook`.

**laptop-old (Mint)** — day-to-day (passwordless sudo is set up by the playbook):

```sh
cd ~/Projects/machine-setup && git pull --ff-only
./scripts/apply.sh laptop-old
```

First run only (before passwordless sudo exists — `-K` asks the sudo password):

```sh
./scripts/apply.sh laptop-old -K
```

**desktop-bazzite** — day-to-day (no passwordless sudo there):

```sh
cd ~/Projects/machine-setup && git pull --ff-only
./scripts/apply.sh desktop-bazzite -e ansible_become=false
```

First run, or whenever a task needs root (e.g. the KeePassXC flatpak install):

```sh
./scripts/apply.sh desktop-bazzite -K
```

Without a terminal to type into (from an IDE or an agent), a desktop dialog asks
the password instead:

```sh
./scripts/apply.sh desktop-bazzite --become-password-file scripts/sudo-askpass.sh
```

**tablet-miix** — the image already gives the user passwordless sudo, so every
run, the first included, is:

```sh
cd ~/Projects/machine-setup && git pull --ff-only
./scripts/apply.sh tablet-miix
```

**Dry run** — show what *would* change (with diffs) without touching anything;
works with any command above:

```sh
./scripts/apply.sh laptop-old --check --diff
```

(Command/shell tasks are skipped in check mode, so on a fresh machine the
prediction is less complete than on an already-provisioned one. With the
bootstrap one-liner, pick `0) clone/update only`, then dry-run by hand.)

**Single role** — the keyring, appimages and graphics roles are tagged; tag more
roles in `site.yml` as needed:

```sh
./scripts/apply.sh laptop-old --tags keyring
./scripts/apply.sh desktop-bazzite --tags appimages -e ansible_become=false
./scripts/apply.sh desktop-bazzite --tags graphics -K
```

Note the difference on Bazzite: most roles there run unprivileged
(`-e ansible_become=false`), but `graphics` writes `/usr/local/bin` and
`/etc/systemd/system`, and `storage` writes crypttab and fstab, so they need
`-K` and a sudo password instead (`storage` skips itself without root).

### Machine-local values (not in git)

Machine identifiers (hardened SSH port, trusted home-gateway MACs,
the private Gitea URL, optionally `primary_user`) live in
`host_vars/<host>/local.yml`, which is **untracked** — the public repo carries
no machine-specific identifiers. On a fresh machine the playbook **prompts** for
any missing value needed by an enabled role and saves it there (mode 0600), so
it only ever asks once. Two of the prompts help you fill them in and can be
postponed:

- **Home-gateway MAC** — it detects the current default gateway's MAC (correct
  only while you are on the home network) and asks you to confirm it, enter
  MAC(s) manually, or **skip**.
- **Git origin** — a checkout bootstrapped from the public GitHub mirror has
  GitHub as its `origin`; the playbook offers to repoint it to the private Gitea
  (**y** = enter the Gitea URL, **n** = keep the current origin and never ask
  again, **s** = skip and ask on the next interactive run).

Skipping (or a non-interactive run) simply leaves that value unset; the
dependent role tasks skip cleanly until you set it on a later run. The SSH port
has no safe default, so it stays required. You can also create the file by hand
before the first run:

```yaml
# host_vars/laptop-old/local.yml
ssh_port: 22
wg_home_gateway_macs:
  - "aa:bb:cc:dd:ee:ff"
git_origin_url: "https://gitea.example/you/machine-setup.git"   # or 'keep'
```

### Checks — local run == CI run

Everything CI checks is one script, and CI runs exactly that script:

```sh
./scripts/check.sh
```

It bootstraps its own toolchain into the gitignored `.venv/` + `.ansible/`
(first run is slower; versions pinned in `requirements.txt` /
`requirements.yml`, both Renovate-managed — the same toolchain
`scripts/apply.sh` uses to run the playbook), then runs: **ansible syntax
check** → **ansible-lint** (`production` profile, config in `.ansible-lint`) →
**secret scan** over the tracked files (private keys, IPv4s, MACs, UUIDs — with
the documentation placeholders allowlisted).

Because the repo is public, the scan's built-in patterns are generic on
purpose. Personal identifiers (your domain, hostnames, ports, ...) go into
**`.secret-patterns.local`** — one extended regex per line, `#` comments
allowed. The file is gitignored and picked up automatically, so your private
patterns guard every local run without ever being published.

Lint exception policy: a rule violated by one deliberate task gets an inline
`# noqa: <rule>` next to a justifying comment; `skip_list` in `.ansible-lint`
is reserved for rules that would force a repo-wide rename (see the comments
there).

### Removing a package
Move its name from `packages_present` to `packages_absent` in the relevant vars
file and re-run. Keep entries in `packages_absent` permanently so fresh installs
stay clean. Never list the same package in both.

## Base install runbook (manual steps)

The base install is interactive and destructive, so it stays a written runbook.
It is deliberately short: everything that *can* be automated happens after first
boot, via the bootstrap + playbook.

### laptop-old (Linux Mint)

1. **Live USB** — boot the Mint (Cinnamon) live USB and verify hardware first:
   Wi-Fi, audio, and both GPUs show up (`inxi -G`; Intel iGPU is the daily
   driver, NVIDIA via nouveau/PRIME is optional — see the `graphics` role).
2. **Install with full-disk encryption on the SSD only**: choose *Erase disk and
   install*, tick *Encrypt the new installation* (LUKS), and pick a strong
   passphrase — this passphrase is the primary unlock and is **never stored
   anywhere**. Create the normal daily user when asked.
3. **Leave the HDD untouched.** It is the encrypted data disk (`storage`
   role); a new, empty disk gets the role's one-time manual bootstrap (see
   `roles/storage/README.md`) — the installer must not touch it.
4. **First boot** — log in and run the bootstrap one-liner (Workflow step 2).
   The playbook prompts once for the machine-local values (SSH port, and the
   postponable gateway-MAC / git-origin prompts) and applies everything else.
5. **Manual follow-ups that need secrets in hand** (each documented in its
   role's README): copy the data disk's keyfile from its KeePassXC entry to
   `/etc/cryptsetup-keys.d/data.key` and re-run the playbook (`storage`),
   import the WireGuard client configs (`wireguard`), and unlock/populate
   KeePassXC so it serves the SSH keys (`keyring`).

### desktop-bazzite (Bazzite)

1. **Install Bazzite (KDE)** on the NVMe system disk; the installer's encryption
   option is the way to an encrypted system disk. Leave both HDDs and the
   Windows SSD untouched.
2. **First boot** — run the bootstrap one-liner, then
   `./scripts/apply.sh desktop-bazzite -K`. The playbook stops at its manual
   gates (Synology Drive sign-in and initial sync, Brave sync, Steam sign-in)
   and asks once for the machine-local values. **Reboot** — the Brave layer and
   the amdgpu kernel argument take effect only then — and run it once more.
3. **Data disks** — copy each disk's keyfile from its KeePassXC entry to
   `/etc/cryptsetup-keys.d/<name>.key` (root, mode 0400), then
   `./scripts/apply.sh desktop-bazzite --tags storage -K`. Without a keyfile a
   disk still opens with its fallback passphrase (see `roles/storage/README.md`).
   The games are still on the data disk, but the launchers have to find them
   again: add `/var/mnt/data/Games/SteamLibrary` in Steam (Settings → Storage),
   and import each game installed under `/mnt/data/Games/Heroic` from its page
   in Heroic (*Import Game*).
4. **AppImages** — `./scripts/apply.sh desktop-bazzite --tags appimages
   -e ansible_become=false -e appimages_install_missing=true`.
5. **KeePassXC** — unlock the database so it serves the SSH keys (`keyring`).
6. **Services from other repositories** — once git can push to the forge (a
   token in the credential store), clone `ai-stack` and `gitea-act-runner` into
   `~/Projects` and run their `scripts/setup.sh`; `ai-stack` also provides the
   Claude Code skills.
7. **Manual by choice**, not in the playbook:
   - virtualization for virt-manager: `ujust setup-virtualization`
   - Waydroid: `sudo waydroid init -c https://ota.waydro.id/system -v https://ota.waydro.id/vendor -s VANILLA`
   - Steam: default compatibility tool *Proton-GE Latest*, and local network
     game transfers (Settings → Downloads)
   - Lutris game entries, KDE panels and widgets, the power profile
   - Radmin VPN joins as a new device on its first start; Bluetooth devices
     need pairing again
8. **Secure Boot** (optional; a TPM unlock of an encrypted system disk needs
   it) — enroll the uBlue key once with `ujust enroll-secure-boot-key` and
   confirm it in the MOK screen at the next boot, then switch Secure Boot on in
   the firmware (`ujust bios`).
