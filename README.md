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
```sh
sudo apt install -y ansible git
git clone http://<gitea-host>/<user>/machine-setup.git
cd machine-setup
```

### 3. Apply locally
```sh
# Runs locally (no SSH), as your user, escalating with sudo only where needed (-K asks the sudo password).
ansible-playbook -c local -l laptop-old -K site.yml
```
`-l <host>` selects which machine's configuration to apply — this is the "switch"
for the multi-host repo.

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
