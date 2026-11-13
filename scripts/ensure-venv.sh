#!/usr/bin/env bash
# Ensure the repo-local toolchain: .venv/ with the pins of requirements.txt
# and, where there is one, requirements-dev.txt.
# It runs on the Python minor version of .python-version: python<version> from
# PATH or the OS Python when it is that version, otherwise one that uv (pinned
# in requirements-uv.txt) downloads into .python/.
# The Ansible collections of requirements.yml go into .ansible/.
# All of it is gitignored and lives inside the checkout, so deleting the repo
# directory removes the whole toolchain: nothing is installed system-wide.
#
# Called by scripts/check.sh and any other script that needs the toolchain;
# safe to run directly.
# Managed by repo-template: changes here are overwritten by its next update.
set -euo pipefail
cd "$(dirname "$0")/.."

VENV=.venv
TOOLS=.python
PY_VERSION="$(cat .python-version)"
# An explicit PYTHON wins; then python<version> from PATH, e.g. a deadsnakes
# build in the CI image; then the OS Python.
PYTHON="${PYTHON:-$(command -v "python$PY_VERSION" || echo python3)}"

# venv needs ensurepip; on Debian, Ubuntu and Mint that is the <python>-venv
# package, python3-venv or python3.15-venv for example.
"$PYTHON" -c 'import ensurepip' 2>/dev/null || {
  echo "ERROR: $PYTHON cannot create a venv (no ensurepip)." >&2
  echo "On Debian, Ubuntu or Mint: sudo apt install $(basename "$PYTHON")-venv" >&2
  exit 1
}

# Succeeds when interpreter $1 runs and is Python $PY_VERSION.
is_pinned_python() {
  "$1" -c 'import sys; sys.exit("%d.%d" % sys.version_info[:2] != sys.argv[1])' \
    "$PY_VERSION" 2>/dev/null
}

# The interpreter to build .venv from: the OS Python, or uv's download of the
# pinned version, kept under .python/ with uv's cache and user config off.
base_python() {
  if is_pinned_python "$PYTHON"; then
    command -v "$PYTHON"
    return
  fi
  local uv="$TOOLS/bootstrap/bin/uv"
  export UV_NO_CONFIG=1 UV_NO_CACHE=1 UV_PYTHON_PREFERENCE=only-managed \
    UV_PYTHON_INSTALL_DIR="$PWD/$TOOLS/interpreters" UV_PYTHON_BIN_DIR="$PWD/$TOOLS/bin"
  "$TOOLS/bootstrap/bin/python" -c '' 2>/dev/null || {
    rm -rf "$TOOLS/bootstrap"
    "$PYTHON" -m venv "$TOOLS/bootstrap"
  }
  "$TOOLS/bootstrap/bin/pip" install --quiet --disable-pip-version-check --no-cache-dir \
    -r requirements-uv.txt >&2
  "$uv" python install --quiet --no-bin "$PY_VERSION" >&2
  "$uv" python find "$PY_VERSION"
}

# Once the OS Python is the pinned version, uv's download is not needed: drop
# it, with the .venv built on it.
if [ -d "$TOOLS" ] && is_pinned_python "$PYTHON"; then
  echo "the OS Python is $PY_VERSION — removing $TOOLS and rebuilding .venv on it"
  rm -rf "$TOOLS" "$VENV"
fi

# A venv breaks silently when the python it symlinks gets upgraded away, or
# loses its pip, and the pin can move on — probe it instead of trusting that
# the files exist.
if [ -d "$VENV" ] && ! { is_pinned_python "$VENV/bin/python" \
    && "$VENV/bin/python" -m pip --version >/dev/null 2>&1; }; then
  echo "existing .venv is broken, has no pip, or is not on Python $PY_VERSION — rebuilding"
  rm -rf "$VENV"
fi

if [ ! -x "$VENV/bin/python" ]; then
  base="$(base_python)"
  "$base" -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
fi

# Fast no-op when already satisfied; picks up Renovate bumps of the pins. A
# requirements-dev.txt, where there is one, holds the tools beside the
# project's own dependencies.
reqs=(-r requirements.txt)
if [ -f requirements-dev.txt ]; then reqs+=(-r requirements-dev.txt); fi
"$VENV/bin/pip" install --quiet "${reqs[@]}"

# The collections' own repositories (github.com/ansible-collections/<name>),
# at their newest release tag, for when Galaxy cannot serve them. Without
# dependencies, which Galaxy would fetch again.
install_from_git() {
  local name tag reqs
  reqs="$(mktemp)"
  echo "collections:" > "$reqs"
  for name in $("$VENV/bin/python" -c 'import sys, yaml; print(" ".join(c["name"] for c in yaml.safe_load(open(sys.argv[1]))["collections"] or []))' requirements.yml); do
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
