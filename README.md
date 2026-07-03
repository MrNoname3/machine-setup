# machine-setup

Reproducible, version-controlled setup for my Linux machines, driven by Ansible
and run **locally** on each machine.

## Goals
- **Followable** — a written runbook for the steps that must stay manual.
- **Reproducible** — idempotent, re-runnable Ansible for everything after first boot.
- **Version-controlled** — this repo is the single source of truth.

## Secrets policy
**NEVER commit secrets** (LUKS keyfiles, passwords, KeePassXC databases, private keys).
This repo is anonymously readable from the local Gitea server, so it must contain
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
├── README.md            # this file — runbook + usage
├── ansible.cfg          # local-run defaults
├── inventory.ini        # hosts and groups (all use local connection)
├── site.yml             # maps each host to its enabled roles
├── group_vars/
│   └── all.yml          # shared variables (package lists, ...)
├── host_vars/
│   └── laptop-old.yml   # per-host settings (roles_enabled, UUIDs, ...)
└── roles/
    ├── base/            # packages (present/absent), common config
    ├── luks-unlock/     # extra LUKS unlock methods (pendrive, dropbear, HDD)
    ├── keyring/         # KeePassXC as Secret Service + SSH agent
    └── graphics/        # nouveau reclocking, PRIME offload (laptop only)
```

## Workflow

### 1. Base install (manual — see runbook below)
The encrypted base install is interactive/destructive and is **not** scripted.
Follow the runbook section.

### 2. Bootstrap (on the freshly installed machine)

Paste this into a terminal (as your normal user — **not** root; needs home
LAN/VPN access to the Gitea server):

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

### 3. Apply / re-apply the playbook

`-l <host>` selects which machine's configuration to apply — this is the
"switch" for the multi-host repo. From `~/Projects/machine-setup`:

| Machine | First run | Day-to-day |
|---|---|---|
| **laptop-old** (Mint) | `ansible-playbook -c local -l laptop-old -K site.yml` | `ansible-playbook -c local -l laptop-old site.yml` (passwordless sudo is set up by the playbook) |
| **desktop-bazzite** | `ansible-playbook -c local -l desktop-bazzite -K site.yml` | `ansible-playbook -c local -l desktop-bazzite -e ansible_become=false site.yml` (no passwordless sudo there; use `-K` when a task needs root) |

On Bazzite, if `ansible-playbook` is not found first:
`eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"`.

Run a single role: append `--tags keyring` (the keyring role is tagged; tag more
roles in `site.yml` as needed).

**Dry run** — see what *would* change without touching anything: append
`--check --diff` to any of the commands above. (Command/shell tasks are skipped
in check mode, so on a fresh machine the prediction is less complete than on an
already-provisioned one; file/package/config changes are shown with diffs.)
Tip: with the bootstrap one-liner, pick `0) clone/update only`, then run the
check command by hand.

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
