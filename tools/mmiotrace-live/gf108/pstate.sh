#!/bin/sh
#
# pstate.sh [level]
#
# Shows nouveau's pstate table, after writing the level first if one is given:
# a hex id such as 0f, or none, which leaves the clocks alone from the next
# time the GPU powers up. A write that blocks in the kernel is left behind after
# 20 seconds, so a hang in the clock code does not take the shell with it.
#
as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

# shellcheck disable=SC2016 # expanded by the inner, privileged shell
file=$(as_root sh -c 'for d in /sys/kernel/debug/dri/*; do
  [ -e "$d/pstate" ] && [ "$(cut -d" " -f1 "$d/name")" = nouveau ] && { echo "$d/pstate"; exit; }
done')
[ -n "$file" ] || { echo "pstate.sh: nouveau has no pstate file" >&2; exit 1; }

if [ $# -ge 1 ]; then
  rc=$(mktemp)
  ( echo "$1" | as_root tee "$file" >/dev/null; echo $? >"$rc" ) &
  i=0
  while [ ! -s "$rc" ] && [ $i -lt 40 ]; do sleep 0.5; i=$((i + 1)); done
  if [ ! -s "$rc" ]; then
    echo "pstate.sh: writing $1 still blocks after 20 s" >&2
    exit 2
  fi
  [ "$(cat "$rc")" = 0 ] || { echo "pstate.sh: writing $1 failed" >&2; rm -f "$rc"; exit 1; }
  rm -f "$rc"
fi
as_root cat "$file"
