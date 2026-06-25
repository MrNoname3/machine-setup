#!/usr/bin/env bash
# Bootstrap a fresh Linux Mint install so Ansible can take over.
#
# Run this ONCE, on the machine, as your normal user. It is interactive and
# uses sudo (it will prompt for your password). This is the minimal, unavoidable
# manual layer (chicken-and-egg): you need ansible + git + the repo before
# `ansible-playbook` can run at all.
#
# Everything else -- passwordless sudo, the SSH server and keys, packages,
# LUKS unlock methods, keyring, graphics -- is desired state and is applied by
# the playbook itself. The very first playbook run uses -K (asks your sudo
# password once); after it configures passwordless sudo, later runs need no -K.
#
# Usage:  ./bootstrap.sh [inventory-host]      (default host: laptop-old)
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/MrNoname3/machine-setup.git}"
REPO_DIR="${REPO_DIR:-$HOME/machine-setup}"
HOST="${1:-laptop-old}"

echo "==> Installing ansible + git..."
sudo apt-get update -y
sudo apt-get install -y ansible git

echo "==> Fetching the configuration repo into $REPO_DIR ..."
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$REPO_DIR"
fi

echo "==> Applying the playbook locally (you will be asked for your sudo password once)..."
cd "$REPO_DIR"
ansible-playbook -c local -l "$HOST" -K site.yml

echo ""
echo "==> Done. Future runs (no -K needed once passwordless sudo is in place):"
echo "      cd $REPO_DIR && git pull && ansible-playbook -c local -l $HOST site.yml"
