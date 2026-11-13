#!/usr/bin/env bash
# Release gate — the single entry point for every repo check.
#
#   ./scripts/check.sh
#
# CI (.github/workflows/ci.yml) runs exactly this script, so a local pass means
# a CI pass. The steps come from scripts/lib/gate.sh (managed by
# repo-template): the toolchain, the ansible syntax check and ansible-lint
# ('production' profile, see .ansible-lint), shellcheck over every tracked
# shell script, and the secret scan. The repository is public, so the scan
# also fails on machine identifiers; the values that only look like one are
# in .secret-allow, and private patterns (own domains, real MACs, ...) in the
# untracked .secret-patterns.local.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/gate.sh
. scripts/lib/gate.sh

gate_toolchain
gate_ansible
gate_shellcheck
gate_secret_scan
gate_done
