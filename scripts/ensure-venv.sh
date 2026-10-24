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

# The collections' own repositories (github.com/ansible-collections/<name>),
# at their newest release tag, for when Galaxy cannot serve them. Without
# dependencies, which Galaxy would fetch again: community.general's serves
# only inventory plugins, and the inventory here is a static file.
install_from_git() {
  local name tag reqs
  reqs="$(mktemp)"
  echo "collections:" > "$reqs"
  for name in $("$VENV/bin/python" -c 'import sys, yaml; print(" ".join(c["name"] for c in yaml.safe_load(open(sys.argv[1]))["collections"]))' requirements.yml); do
    tag="$(git ls-remote --tags --refs "https://github.com/ansible-collections/$name.git" \
      | sed -n 's#.*refs/tags/\([0-9]*\.[0-9]*\.[0-9]*\)$#\1#p' | sort -V | tail -1)"
    [ -n "$tag" ] || { rm -f "$reqs"; return 1; }
    printf '  - name: https://github.com/ansible-collections/%s.git\n    type: git\n    version: %s\n' \
      "$name" "$tag" >> "$reqs"
  done
  "$VENV/bin/ansible-galaxy" collection install --no-deps -r "$reqs" -p .ansible/collections >/dev/null
  local rc=$?
  rm -f "$reqs"
  return $rc
}

# galaxy.ansible.com is occasionally flaky — retry a couple of times, then
# take the collections from their repositories (pip already retries its
# downloads on its own).
for attempt in 1 2 3; do
  if "$VENV/bin/ansible-galaxy" collection install -r requirements.yml \
    -p .ansible/collections >/dev/null; then
    break
  elif [ "$attempt" = 3 ]; then
    echo "ansible-galaxy failed 3 times; installing the collections from their git repositories" >&2
    install_from_git || {
      echo "ERROR: could not install the collections from Galaxy or git" >&2
      exit 1
    }
  else
    echo "ansible-galaxy failed (attempt $attempt), retrying..." >&2
    sleep 5
  fi
done
