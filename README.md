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
  SSD + HDD, Optimus. Target distro: Linux Mint.
- **desktop-bazzite** — main desktop, Bazzite (immutable, rpm-ostree). Uses a different
  package model than apt; the `base` role's apt tasks are guarded and will not run here.

## Repository layout
```
machine-setup/
├── README.md                    # this file — runbook + usage
├── bootstrap.sh                 # curl-able bootstrap (see Workflow step 2)
├── machine-setup.code-workspace # portable VS Code workspace
├── ansible.cfg                  # local-run defaults
├── inventory.ini                # hosts and groups (all use local connection)
├── site.yml                     # maps each host to its enabled roles
├── group_vars/
│   └── all.yml                  # shared variables (package lists, ssh_keys_dir, ...)
├── host_vars/
│   ├── laptop-old.yml           # per-host settings (roles_enabled, UUIDs, ...)
│   └── desktop-bazzite.yml
└── roles/
    ├── base/            # packages (present/absent), sudo, MIME/dconf defaults
    ├── ssh-access/      # hardened SSH server
    ├── brave/           # browser
    ├── synology-drive/  # Synology Drive client
    ├── steam/           # Steam (+ flatpak on Bazzite)
    ├── vscode/          # VS Code + settings + extensions
    ├── luks-unlock/     # extra LUKS unlock methods (pendrive, dropbear, HDD)
    ├── keyring/         # KeePassXC as the SSH agent (both OSes)
    ├── kde/             # Plasma desktop tweaks (Bazzite)
    ├── graphics/        # nouveau reclocking, PRIME offload (laptop only)
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

It installs git + ansible the OS-appropriate way (apt on Mint, Homebrew on
Bazzite), clones this repo to `~/Projects/machine-setup`, then shows a host menu
(read from `inventory.ini`, so new machines appear automatically) and offers to
run the playbook right away. Idempotent — safe to re-run any time.

Non-interactive variant (picks the host and runs immediately):

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MrNoname3/machine-setup/main/bootstrap.sh)" -- laptop-old
```

> The `bash -c "$(curl ...)"` form (instead of `curl | bash`) keeps stdin on the
> terminal so the menu can prompt.

At home you can clone from the local Gitea instead (it mirrors to GitHub on
every push): prefix the command with `REPO_URL=<gitea-clone-url>`.

### 3. Apply / re-apply the playbook

`-l <host>` selects which machine's configuration to apply — this is the
"switch" for the multi-host repo.

**laptop-old (Mint)** — day-to-day (passwordless sudo is set up by the playbook):

```sh
cd ~/Projects/machine-setup && git pull --ff-only
ansible-playbook -c local -l laptop-old site.yml
```

First run only (before passwordless sudo exists — `-K` asks the sudo password):

```sh
ansible-playbook -c local -l laptop-old -K site.yml
```

**desktop-bazzite** — day-to-day (no passwordless sudo there):

```sh
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"   # only if ansible-playbook is not on PATH
cd ~/Projects/machine-setup && git pull --ff-only
ansible-playbook -c local -l desktop-bazzite -e ansible_become=false site.yml
```

First run, or whenever a task needs root (e.g. the KeePassXC flatpak install):

```sh
ansible-playbook -c local -l desktop-bazzite -K site.yml
```

**Dry run** — show what *would* change (with diffs) without touching anything;
works with any command above:

```sh
ansible-playbook -c local -l laptop-old site.yml --check --diff
```

(Command/shell tasks are skipped in check mode, so on a fresh machine the
prediction is less complete than on an already-provisioned one. With the
bootstrap one-liner, pick `0) clone/update only`, then dry-run by hand.)

**Single role** — the keyring role is tagged; tag more roles in `site.yml` as
needed:

```sh
ansible-playbook -c local -l laptop-old site.yml --tags keyring
```

### Removing a package
Move its name from `packages_present` to `packages_absent` in the relevant vars
file and re-run. Keep entries in `packages_absent` permanently so fresh installs
stay clean. Never list the same package in both.

## Base install runbook (manual steps)
> TODO: fill in exact partitioning + LUKS + Mint installer choices.
> The full plan and rationale live in `memory/old-laptop-linux-plan.md`.

1. Boot the Mint live USB; verify hardware (Wi-Fi, audio, NVIDIA/Intel).
2. Partition + enable LUKS full-disk encryption on the SSD during install.
3. Leave the HDD untouched (encrypt it later via the `luks-unlock` role).
4. First boot, then run the bootstrap + apply steps above.
