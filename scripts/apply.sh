#!/usr/bin/env bash
# Apply the playbook with the repo-local toolchain — no system-wide ansible
# needed (or wanted): scripts/ensure-venv.sh bootstraps everything into the
# gitignored .venv/ + .ansible/ on first use.
#
#   ./scripts/apply.sh <inventory-host> [extra ansible-playbook args...]
#
# Examples:
#   ./scripts/apply.sh laptop-old                        # day-to-day (passwordless sudo)
#   ./scripts/apply.sh laptop-old -K                     # first run: asks the sudo password
#   ./scripts/apply.sh desktop-bazzite -e ansible_become=false
#   ./scripts/apply.sh laptop-old --check --diff         # dry run
#   ./scripts/apply.sh laptop-old --tags keyring         # just a tagged role
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -ge 1 ] || { echo "usage: $0 <inventory-host> [ansible-playbook args...]" >&2; exit 1; }
HOST="$1"; shift

./scripts/ensure-venv.sh
export ANSIBLE_COLLECTIONS_PATH="$PWD/.ansible/collections"
exec .venv/bin/ansible-playbook -c local -l "$HOST" "$@" site.yml
