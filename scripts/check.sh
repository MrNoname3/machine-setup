#!/usr/bin/env bash
# Release gate — the single entry point for every repo check.
#
#   ./scripts/check.sh
#
# CI (.github/workflows/ci.yml) runs exactly this script, so a local pass means
# a CI pass. Steps:
#   1. toolchain bootstrap  — venv in .venv/ (gitignored), ansible-lint via pip
#   2. galaxy collections   — requirements.yml into .ansible/ (gitignored)
#   3. ansible syntax check
#   4. ansible-lint         — 'production' profile (see .ansible-lint)
#   5. secret scan          — tracked files only; generic patterns below, plus
#                             optional private patterns from .secret-patterns.local
#                             (gitignored — put machine/domain identifiers there,
#                             one extended regex per line, '#' comments allowed)
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHON="${PYTHON:-python3}"
VENV=.venv

step() { printf '\n=== %s ===\n' "$1"; }

step "toolchain (.venv)"
if [ ! -x "$VENV/bin/ansible-lint" ]; then
  "$PYTHON" -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet ansible-lint
fi
"$VENV/bin/ansible-lint" --version

step "galaxy collections (.ansible)"
export ANSIBLE_COLLECTIONS_PATH="$PWD/.ansible/collections"
"$VENV/bin/ansible-galaxy" collection install -r requirements.yml \
  -p "$ANSIBLE_COLLECTIONS_PATH" >/dev/null
echo "OK"

step "ansible syntax check"
"$VENV/bin/ansible-playbook" --syntax-check -i inventory.ini site.yml

step "ansible-lint"
"$VENV/bin/ansible-lint"

step "secret scan (tracked files)"
# The repo is public: no machine identifiers may be committed. These patterns
# are deliberately generic — private patterns (own domains, real MACs, ...)
# belong in the untracked .secret-patterns.local, NOT here.
fail=0

scan() { # scan <label> <pattern-ERE> [allowlist-ERE]
  local label="$1" pattern="$2" allow="${3:-}" hits
  hits="$(git grep -nEI -e "$pattern" -- ':(exclude)scripts/check.sh' || true)"
  if [ -n "$allow" ] && [ -n "$hits" ]; then
    hits="$(printf '%s\n' "$hits" | grep -vE -- "$allow" || true)"
  fi
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
    echo "FAIL: possible secret in tracked files ($label)"
    fail=1
  fi
}

scan "private key block" 'BEGIN [A-Z ]*PRIVATE KEY'
scan "IPv4 address" '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' \
  '0\.0\.0\.0|127\.0\.0\.1|192\.168\.0\.0/16|10\.0\.0\.0/8|172\.16\.0\.0/12'
scan "MAC address" '\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b' \
  'aa:bb:cc:dd:ee:ff'
scan "UUID" '\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'

if [ -f .secret-patterns.local ]; then
  while IFS= read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    scan "local pattern" "$p"
  done < .secret-patterns.local
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "Secret scan failed. False positive? Extend the allowlist in scripts/check.sh."
  exit 1
fi
echo "OK"

printf '\nAll checks passed.\n'
