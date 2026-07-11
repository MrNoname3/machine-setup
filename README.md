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
│   ├── laptop-old/
│   │   ├── main.yml             # per-host settings (roles_enabled, ...)
│   │   └── local.yml            # machine identifiers — untracked; prompted+saved by site.yml
│   └── desktop-bazzite/         # same layout (main.yml + untracked local.yml)
└── roles/
    ├── base/            # packages (present/absent), sudo, MIME/dconf defaults
    ├── ssh-access/      # hardened SSH server
    ├── brave/           # browser
    ├── synology-drive/  # Synology Drive client
    ├── steam/           # Steam (+ flatpak on Bazzite)
    ├── vscode/          # VS Code + settings + extensions
    ├── luks-unlock/     # remote root unlock at boot (dropbear in the initramfs)
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

### Machine-local values (not in git)

Machine identifiers (hardened SSH port, LUKS UUIDs, trusted home-gateway MACs,
the private Gitea URL, optionally `primary_user`) live in
`host_vars/<host>/local.yml`, which is **untracked** — the public repo carries
no machine-specific identifiers. On a fresh machine the playbook **prompts** for
any missing value needed by an enabled role and saves it there (mode 0600), so
it only ever asks once. Three of the prompts help you fill them in and can be
postponed:

- **Data-disk LUKS UUID** — the playbook scans for `crypto_LUKS` partitions
  (excluding the root disk) and offers them by size/UUID; pick one, type a UUID
  by hand, or choose **skip**.
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
luks_hdd_uuid: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
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
(first run is slower), then runs: **ansible syntax check** → **ansible-lint**
(`production` profile, config in `.ansible-lint`) → **secret scan** over the
tracked files (private keys, IPv4s, MACs, UUIDs — with the documentation
placeholders allowlisted).

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

1. **Live USB** — boot the Mint (Cinnamon) live USB and verify hardware first:
   Wi-Fi, audio, and both GPUs show up (`inxi -G`; Intel iGPU is the daily
   driver, NVIDIA via nouveau/PRIME is optional — see the `graphics` role).
2. **Install with full-disk encryption on the SSD only**: choose *Erase disk and
   install*, tick *Encrypt the new installation* (LUKS), and pick a strong
   passphrase — this passphrase is the primary unlock and is **never stored
   anywhere**. Create the normal daily user when asked.
3. **Leave the HDD untouched.** The data disk is encrypted later with the
   `storage` role's one-time manual bootstrap (see `roles/storage/README.md`) —
   the installer must not touch it.
4. **First boot** — log in and run the bootstrap one-liner (Workflow step 2).
   The playbook prompts once for the machine-local values (SSH port, and the
   postponable LUKS-UUID / gateway-MAC / git-origin prompts) and applies
   everything else.
5. **Manual follow-ups that need secrets in hand** (each documented in its
   role's README): add the HDD fallback passphrase (`storage`), import the
   WireGuard client configs (`wireguard`), and unlock/populate KeePassXC so it
   serves the SSH keys (`keyring`).
