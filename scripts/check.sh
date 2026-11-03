#!/usr/bin/env bash
# Release gate — the single entry point for every repo check.
#
#   ./scripts/check.sh
#
# CI (.github/workflows/ci.yml) runs exactly this script, so a local pass means
# a CI pass. Steps:
#   1. toolchain            — scripts/ensure-venv.sh: pinned Python and python
#                             tools (.python-version, requirements*.txt) +
#                             galaxy collections into the gitignored .python/ +
#                             .venv/ + .ansible/
#   2. ansible syntax check
#   3. ansible-lint         — 'production' profile (see .ansible-lint)
#   4. shellcheck           — every tracked shell script (see .shellcheckrc)
#   5. secret scan          — tracked files only; generic patterns below, plus
#                             optional private patterns from .secret-patterns.local
#                             (gitignored — put machine/domain identifiers there,
#                             one extended regex per line, '#' comments allowed)
set -euo pipefail
cd "$(dirname "$0")/.."

VENV=.venv

step() { printf '\n=== %s ===\n' "$1"; }

step "toolchain (.venv + collections)"
./scripts/ensure-venv.sh
export ANSIBLE_COLLECTIONS_PATH="$PWD/.ansible/collections"
# The interpreter .venv is built on: the OS Python or uv's download in .python/.
"$VENV/bin/python" -c 'import os, sys
base = os.path.realpath(sys._base_executable)
print("Python", sys.version.split()[0], "from",
      os.path.relpath(base) if base.startswith(os.getcwd() + os.sep) else base)'
"$VENV/bin/ansible-lint" --version
"$VENV/bin/shellcheck" --version | sed -n 2p

step "ansible syntax check"
"$VENV/bin/ansible-playbook" --syntax-check -i inventory.ini site.yml

step "ansible-lint"
"$VENV/bin/ansible-lint"

step "shellcheck"
# *.sh files and files with a shell shebang; Jinja templates are not shell yet.
mapfile -t shell_scripts < <(git ls-files ':(exclude)*.j2' | while IFS= read -r f; do
  case "$f" in
    *.sh) echo "$f" ;;
    *) head -n 1 -- "$f" 2>/dev/null | grep -qE '^#!.*\b(ba|da)?sh\b' && echo "$f" ;;
  esac
done)
"$VENV/bin/shellcheck" "${shell_scripts[@]}"
echo "OK (${#shell_scripts[@]} scripts)"

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
# Allowlisted: the four-part version pins in requirements.txt.
scan "IPv4 address" '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' \
  '0\.0\.0\.0|127\.0\.[01]\.1|192\.168\.0\.0/16|10\.0\.0\.0/8|172\.16\.0\.0/12|^requirements\.txt:[0-9]+:[A-Za-z0-9_.-]+==[0-9.]+$'
scan "MAC address" '\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b' \
  'aa:bb:cc:dd:ee:ff'
# Allowlisted: the GPT type of a Linux x86-64 root partition, the vendor GUID
# of the Lenovo firmware's Setup variable, and the ID of Brave's built-in
# DuckDuckGo engine — fixed values, not identifiers.
scan "UUID" '\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b' \
  '4f68bce3-e8cd-4db1-96e7-fbcaf984b709|a04a27f4-df00-4d42-b552-39511302113d|485bf7d3-0215-45af-87dc-538868000501'

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
