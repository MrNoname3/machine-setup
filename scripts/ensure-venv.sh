#!/usr/bin/env bash
# Ensure the repo-local toolchain: .venv/ (python: ansible-core + ansible-lint,
# pinned in requirements.txt) and .ansible/ (galaxy collections from
# requirements.yml). Both are gitignored and live inside the checkout, so
# deleting the repo directory removes the whole toolchain — nothing is
# installed system-wide.
#
# Called by scripts/check.sh and scripts/apply.sh; safe to run directly.
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHON="${PYTHON:-python3}"
VENV=.venv

# venv needs ensurepip; on Debian/Mint that is the python3-venv package.
"$PYTHON" -c 'import ensurepip' 2>/dev/null || {
  echo "ERROR: $PYTHON cannot create a venv (no ensurepip)." >&2
  echo "On Debian/Mint: sudo apt install python3-venv" >&2
  exit 1
}

# A venv breaks silently when the OS python it symlinks gets upgraded away —
# probe it instead of trusting that the files exist.
if [ -d "$VENV" ] && ! "$VENV/bin/python" -c '' 2>/dev/null; then
  echo "existing .venv is broken (OS python changed?) — rebuilding"
  rm -rf "$VENV"
fi

if [ ! -x "$VENV/bin/python" ]; then
  "$PYTHON" -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
fi

# Fast no-op when already satisfied; picks up Renovate bumps of the pins.
"$VENV/bin/pip" install --quiet -r requirements.txt

"$VENV/bin/ansible-galaxy" collection install -r requirements.yml \
  -p .ansible/collections >/dev/null
